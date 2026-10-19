#pragma once

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <unistd.h>

/**
 * Steam's chromehtml.dylib destroys its CSharedMemStream at exit by locking a cross-process semaphore with an
 * infinite timeout. If the Steam Helper left that semaphore held, the exiting client polls it forever: no UI,
 * no IPC, SIGTERM is swallowed by Steam's own handler. This bounds the whole exit instead. It is armed from an
 * atexit handler registered once a Helper is up (handlers run newest first, so it runs before chromehtml's
 * destructors) and cancelled by StopMillennium, which runs after them and before libmillennium is unloaded.
 */
class exit_watchdog
{
  public:
    static constexpr std::chrono::seconds deadline{ 15 };

    static exit_watchdog& get()
    {
        /* Deliberately leaked like millennium_lifecycle: it is used while static destructors run. */
        static exit_watchdog* instance = new exit_watchdog();
        return *instance;
    }

    void register_at_exit()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_registrations >= max_registrations) return;
        ++m_registrations;
        std::atexit(arm_on_exit);
    }

    void cancel()
    {
        std::thread watcher;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_cancelled = true;
            watcher = std::move(m_thread);
        }
        m_cv.notify_all();
        if (watcher.joinable()) watcher.join();
    }

    exit_watchdog(const exit_watchdog&) = delete;
    exit_watchdog& operator=(const exit_watchdog&) = delete;

  private:
    /* Each Helper start registers again, in case chromehtml registered more destructors since the last one. */
    static constexpr int max_registrations = 8;

    exit_watchdog() = default;

    static void arm_on_exit()
    {
        get().arm();
    }

    void arm()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_cancelled || m_thread.joinable()) return;
        try {
            m_thread = std::thread([this]
            {
                std::unique_lock<std::mutex> wait_lock(m_mutex);
                if (!m_cv.wait_for(wait_lock, deadline, [this] { return m_cancelled; })) {
                    _exit(0);
                }
            });
        } catch (...) {
            /* Without a thread the exit is simply unbounded, as before. */
        }
    }

    std::mutex m_mutex;
    std::condition_variable m_cv;
    std::thread m_thread;
    bool m_cancelled = false;
    int m_registrations = 0;
};
