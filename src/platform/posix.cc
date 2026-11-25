/**
 * ==================================================
 *   _____ _ _ _             _
 *  |     |_| | |___ ___ ___|_|_ _ _____
 *  | | | | | | | -_|   |   | | | |     |
 *  |_|_|_|_|_|_|___|_|_|_|_|_|___|_|_|_|
 *
 * ==================================================
 *
 * Copyright (c) 2026 Project Millennium
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include "millennium/steam_hooks.h"
#include <memory>
#if defined(__linux__) || defined(__APPLE__)

#include "millennium/millennium.h"
#include "millennium/environment.h"
#include "millennium/platform_hooks.h"
#include "millennium/logger.h"

#include <signal.h>
#include <stdlib.h>
#include <thread>
#include <unistd.h>

std::unique_ptr<std::thread> g_millenniumThread;
#include "millennium/millennium_lifecycle.h"
#ifdef __APPLE__
#include "millennium/exit_watchdog.h"
#endif

CONSTRUCTOR void Posix_InitializeEnvironment()
{
    if (!platform::should_setup_environment()) {
        return;
    }

    /** Setup environment variables if loaded into Steam process */
    platform::environment::setup();
}

DESTRUCTOR void Posix_UnInitializeEnvironment()
{
}

void Posix_AttachMillennium()
{
    /** Handle signal interrupts (^C) */
    signal(SIGINT, [](int /** signalCode */)
    {
        std::exit(128 + SIGINT);
    });

    platform::before_attach_millennium();
    platform::initialize_steam_hooks();
    g_millennium = std::make_unique<millennium>();
    g_millennium->entry();
}

/** New interop funcs that receive calls from hooked libXtst */
extern "C" __attribute__((visibility("default"))) int StartMillennium()
{
    logger.log("Hooked main() with PID: {}", getpid());

    g_millenniumThread = std::make_unique<std::thread>(Posix_AttachMillennium);
    logger.log("Millennium started successfully.");
    return 0;
}

/** Stops the runtime thread (plugin backends, frontend, MEP server) and destroys Millennium. Safe to call twice. */
static void Posix_DetachMillennium()
{
    /* exit() reached from the runtime thread itself (the SIGINT handler): it cannot join itself. */
    if (g_millenniumThread && g_millenniumThread->get_id() == std::this_thread::get_id()) {
        return;
    }

    millennium_lifecycle::get().terminate.notify();

    if (g_millenniumThread && g_millenniumThread->joinable()) {
        g_millenniumThread->join();
    }

    g_millennium.reset();
}

#ifdef __APPLE__
/**
 * Called by the macOS bootstrap's exit() interposer, before exit() runs any atexit handler or static destructor.
 *
 * StopMillennium runs from bootstrap_cleanup, an atexit handler registered right after this library was loaded, so
 * exit() first runs every handler registered later: Steam's static destructors and the destructor of every
 * function-local static of this library first used after startup (get_plugin_logger_mgr(), get_steam_path(), ...).
 * Millennium's threads keep running meanwhile, and the teardown (plugin SHUTDOWN RPCs, backend log lines, reader
 * threads) then uses freed memory. The heap corruption shows up as SIGSEGV in mfm_free (from ~PluginProcess or a
 * thread's TSD cleanup) or as std::thread::join throwing in backend_manager::shutdown. Stopping here avoids it.
 */
extern "C" __attribute__((visibility("default"))) int MillenniumBeforeExit()
{
    logger.log("Steam is exiting; stopping Millennium before static destructors run...");
    Posix_DetachMillennium();
    return 0;
}
#endif

extern "C" __attribute__((visibility("default"))) int StopMillennium()
{
    logger.log("Unloading Millennium...");
    Posix_DetachMillennium();
    platform::after_detach_millennium();

#ifdef __APPLE__
    /* Steam's own exit-time destructors are done; join the watchdog before the bootstrap unloads this library. */
    exit_watchdog::get().cancel();
#endif

    logger.log("Millennium unloaded successfully.");
    return 0;
}
#endif
