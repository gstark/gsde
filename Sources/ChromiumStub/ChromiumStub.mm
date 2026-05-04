#include "ChromiumStub.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <atomic>
#include <new>

typedef std::atomic<int> atomic_int;
static inline int atomic_load(const atomic_int *value) { return value->load(std::memory_order_seq_cst); }
static inline int atomic_fetch_add(atomic_int *value, int increment) { return value->fetch_add(increment, std::memory_order_seq_cst); }
static inline int atomic_fetch_sub(atomic_int *value, int decrement) { return value->fetch_sub(decrement, std::memory_order_seq_cst); }
static inline void atomic_store(atomic_int *value, int desired) { value->store(desired, std::memory_order_seq_cst); }
static inline void atomic_init(atomic_int *value, int desired) { value->store(desired, std::memory_order_seq_cst); }
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if __has_include("include/capi/cef_app_capi.h")
#define GSDE_HAVE_CEF_HEADERS 1
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_cookie_capi.h"
#include "include/internal/cef_string.h"
#else
#define GSDE_HAVE_CEF_HEADERS 0
#endif

static void *cef_handle = NULL;
static bool attempted_load = false;
static bool initialized = false;
static char status[512] = "CEF has not been initialized";
static char last_error[512] = "No CEF errors recorded";
static atomic_int next_browser_id{1};
static atomic_int live_browser_count{0};
static char global_cache_path[4096] = {0};

#if GSDE_HAVE_CEF_HEADERS
typedef int (*cef_execute_process_fn)(const cef_main_args_t *, cef_app_t *, void *);
typedef int (*cef_initialize_fn)(const cef_main_args_t *, const cef_settings_t *, cef_app_t *, void *);
typedef void (*cef_do_message_loop_work_fn)(void);
typedef void (*cef_shutdown_fn)(void);
typedef int (*cef_browser_host_create_browser_fn)(const cef_window_info_t *, cef_client_t *, const cef_string_t *, const cef_browser_settings_t *, cef_dictionary_value_t *, cef_request_context_t *);
typedef cef_browser_t *(*cef_browser_host_create_browser_sync_fn)(const cef_window_info_t *, cef_client_t *, const cef_string_t *, const cef_browser_settings_t *, cef_dictionary_value_t *, cef_request_context_t *);
typedef cef_request_context_t *(*cef_request_context_create_context_fn)(const cef_request_context_settings_t *, cef_request_context_handler_t *);
typedef int (*cef_string_utf8_to_utf16_fn)(const char *, size_t, cef_string_utf16_t *);
typedef int (*cef_string_utf16_to_utf8_fn)(const char16_t *, size_t, cef_string_utf8_t *);
typedef void (*cef_string_utf16_clear_fn)(cef_string_utf16_t *);
typedef void (*cef_string_utf8_clear_fn)(cef_string_utf8_t *);
typedef void (*cef_string_userfree_utf16_free_fn)(cef_string_userfree_utf16_t);
typedef const char *(*cef_api_hash_fn)(int, int);
typedef int (*cef_api_version_fn)(void);

static cef_execute_process_fn cef_execute_process_ptr = NULL;
static cef_initialize_fn cef_initialize_ptr = NULL;
static cef_do_message_loop_work_fn cef_do_message_loop_work_ptr = NULL;
static cef_shutdown_fn cef_shutdown_ptr = NULL;
static cef_browser_host_create_browser_fn cef_browser_host_create_browser_ptr = NULL;
static cef_browser_host_create_browser_sync_fn cef_browser_host_create_browser_sync_ptr = NULL;
static cef_request_context_create_context_fn cef_request_context_create_context_ptr = NULL;
static cef_string_utf8_to_utf16_fn cef_string_utf8_to_utf16_ptr = NULL;
static cef_string_utf16_to_utf8_fn cef_string_utf16_to_utf8_ptr = NULL;
static cef_string_utf16_clear_fn cef_string_utf16_clear_ptr = NULL;
static cef_string_utf8_clear_fn cef_string_utf8_clear_ptr = NULL;
static cef_string_userfree_utf16_free_fn cef_string_userfree_utf16_free_ptr = NULL;
static cef_api_hash_fn cef_api_hash_ptr = NULL;
static cef_api_version_fn cef_api_version_ptr = NULL;
static cef_app_t *gsde_cef_app(void);
#endif

static void gsde_log(const char *message) {
    FILE *file = fopen("/tmp/gsde_chromium.log", "a");
    if (!file) return;
    fprintf(file, "%s\n", message ? message : "(null)");
    fclose(file);
}

static void set_last_error(const char *message) {
    snprintf(last_error, sizeof(last_error), "%s", message ? message : "unknown CEF error");
    gsde_log(last_error);
}

const char *gsde_chromium_last_error(void) {
    return last_error;
}

static void log_live_browser_count(const char *prefix) {
    char message[128];
    snprintf(message, sizeof(message), "%s live CEF browsers: %d", prefix ? prefix : "CEF", atomic_load(&live_browser_count));
    gsde_log(message);
}

static bool load_cef_framework(void) {
    if (cef_handle) return true;
    if (attempted_load) return false;
    attempted_load = true;

    const char *paths[] = {
        "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework",
        "external/cef/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework",
        NULL,
    };

    for (int i = 0; paths[i] != NULL; i++) {
        cef_handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (cef_handle) break;
    }

    if (!cef_handle) {
        const char *err = dlerror();
        snprintf(status, sizeof(status), "CEF framework not found. Run make cef and make app-with-chromium. Last dlopen error: %s", err ? err : "unknown");
        set_last_error(status);
        return false;
    }

#if GSDE_HAVE_CEF_HEADERS
    cef_execute_process_ptr = (cef_execute_process_fn)dlsym(cef_handle, "cef_execute_process");
    cef_initialize_ptr = (cef_initialize_fn)dlsym(cef_handle, "cef_initialize");
    cef_do_message_loop_work_ptr = (cef_do_message_loop_work_fn)dlsym(cef_handle, "cef_do_message_loop_work");
    cef_shutdown_ptr = (cef_shutdown_fn)dlsym(cef_handle, "cef_shutdown");
    cef_browser_host_create_browser_ptr = (cef_browser_host_create_browser_fn)dlsym(cef_handle, "cef_browser_host_create_browser");
    cef_browser_host_create_browser_sync_ptr = (cef_browser_host_create_browser_sync_fn)dlsym(cef_handle, "cef_browser_host_create_browser_sync");
    cef_request_context_create_context_ptr = (cef_request_context_create_context_fn)dlsym(cef_handle, "cef_request_context_create_context");
    cef_string_utf8_to_utf16_ptr = (cef_string_utf8_to_utf16_fn)dlsym(cef_handle, "cef_string_utf8_to_utf16");
    cef_string_utf16_to_utf8_ptr = (cef_string_utf16_to_utf8_fn)dlsym(cef_handle, "cef_string_utf16_to_utf8");
    cef_string_utf16_clear_ptr = (cef_string_utf16_clear_fn)dlsym(cef_handle, "cef_string_utf16_clear");
    cef_string_utf8_clear_ptr = (cef_string_utf8_clear_fn)dlsym(cef_handle, "cef_string_utf8_clear");
    cef_string_userfree_utf16_free_ptr = (cef_string_userfree_utf16_free_fn)dlsym(cef_handle, "cef_string_userfree_utf16_free");
    cef_api_hash_ptr = (cef_api_hash_fn)dlsym(cef_handle, "cef_api_hash");
    cef_api_version_ptr = (cef_api_version_fn)dlsym(cef_handle, "cef_api_version");

    if (!cef_execute_process_ptr || !cef_initialize_ptr || !cef_do_message_loop_work_ptr || !cef_shutdown_ptr || !cef_browser_host_create_browser_ptr || !cef_browser_host_create_browser_sync_ptr || !cef_request_context_create_context_ptr || !cef_string_utf8_to_utf16_ptr || !cef_string_utf16_to_utf8_ptr || !cef_string_utf16_clear_ptr || !cef_string_utf8_clear_ptr || !cef_string_userfree_utf16_free_ptr || !cef_api_hash_ptr || !cef_api_version_ptr) {
        snprintf(status, sizeof(status), "CEF framework loaded, but required C API symbols were missing");
        set_last_error(status);
        return false;
    }

    (void)cef_api_hash_ptr(CEF_API_VERSION, 0);
    snprintf(status, sizeof(status), "CEF framework loaded; bridge ready to initialize; API version %d", cef_api_version_ptr());
    return true;
#else
    snprintf(status, sizeof(status), "CEF framework found, but CEF headers were not available at compile time");
    return false;
#endif
}

const char *gsde_chromium_backend_status(void) {
    load_cef_framework();
    return status;
}

int gsde_chromium_cef_available(void) {
    return load_cef_framework() ? 1 : 0;
}

int gsde_chromium_execute_process(int argc, char **argv) {
#if GSDE_HAVE_CEF_HEADERS
    if (!load_cef_framework()) return -1;
    cef_main_args_t args = { .argc = argc, .argv = argv };
    return cef_execute_process_ptr(&args, gsde_cef_app(), NULL);
#else
    (void)argc;
    (void)argv;
    return -1;
#endif
}

int gsde_chromium_initialize(const char *root_cache_path, const char *cache_path, const char *browser_subprocess_path) {
#if GSDE_HAVE_CEF_HEADERS
    if (initialized) return 1;
    if (!load_cef_framework()) return 0;

    char program_name[] = "GSDE";
    char *argv[] = { program_name };
    cef_main_args_t args = { .argc = 1, .argv = argv };
    cef_settings_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.size = sizeof(settings);
    settings.no_sandbox = 1;
    settings.external_message_pump = 0;
    settings.multi_threaded_message_loop = 0;

    if (root_cache_path && root_cache_path[0] != '\0') {
        cef_string_utf8_to_utf16_ptr(root_cache_path, strlen(root_cache_path), &settings.root_cache_path);
    }
    if (cache_path && cache_path[0] != '\0') {
        snprintf(global_cache_path, sizeof(global_cache_path), "%s", cache_path);
        cef_string_utf8_to_utf16_ptr(cache_path, strlen(cache_path), &settings.cache_path);
        settings.persist_session_cookies = 1;
    }
    if (browser_subprocess_path && browser_subprocess_path[0] != '\0') {
        cef_string_utf8_to_utf16_ptr(browser_subprocess_path, strlen(browser_subprocess_path), &settings.browser_subprocess_path);
    }

    gsde_log("calling cef_initialize");
    int ok = cef_initialize_ptr(&args, &settings, gsde_cef_app(), NULL);
    cef_string_utf16_clear_ptr(&settings.root_cache_path);
    cef_string_utf16_clear_ptr(&settings.cache_path);
    cef_string_utf16_clear_ptr(&settings.browser_subprocess_path);

    initialized = ok != 0;
    snprintf(status, sizeof(status), initialized ? "CEF initialized" : "CEF initialization failed; helper app packaging may be incomplete");
    gsde_log(status);
    if (!initialized) set_last_error(status);
    return initialized ? 1 : 0;
#else
    (void)root_cache_path;
    (void)cache_path;
    (void)browser_subprocess_path;
    snprintf(status, sizeof(status), "CEF initialization unavailable; CEF headers were not present at compile time");
    return 0;
#endif
}

void gsde_chromium_do_message_loop_work(void) {
#if GSDE_HAVE_CEF_HEADERS
    if (initialized && cef_do_message_loop_work_ptr) cef_do_message_loop_work_ptr();
#endif
}

void gsde_chromium_shutdown(void) {
#if GSDE_HAVE_CEF_HEADERS
    if (initialized && cef_shutdown_ptr) {
        cef_shutdown_ptr();
        initialized = false;
        snprintf(status, sizeof(status), "CEF shut down");
        gsde_log(status);
    }
#endif
}

int gsde_chromium_live_browser_count(void) {
    return atomic_load(&live_browser_count);
}

#if GSDE_HAVE_CEF_HEADERS
struct gsde_chromium_browser {
    gsde_chromium_browser()
        : client{},
          life_span_handler{},
          load_handler{},
          display_handler{},
          context_menu_handler{},
          download_handler{},
          find_handler{},
          permission_handler{},
          request_handler{},
          ref_count{1},
          browser(nullptr),
          view(nullptr),
          request_context(nullptr),
          browser_id(0),
          current_url{},
          title{},
          status_message{},
          is_loading(0),
          http_status(0),
          loading_progress(0.0),
          destroy_requested(0) {}

    ~gsde_chromium_browser() {
        if (request_context && request_context->base.base.release) {
            request_context->base.base.release((cef_base_ref_counted_t *)request_context);
            request_context = nullptr;
        }
    }

    cef_client_t client;
    cef_life_span_handler_t life_span_handler;
    cef_load_handler_t load_handler;
    cef_display_handler_t display_handler;
    cef_context_menu_handler_t context_menu_handler;
    cef_download_handler_t download_handler;
    cef_find_handler_t find_handler;
    cef_permission_handler_t permission_handler;
    cef_request_handler_t request_handler;
    atomic_int ref_count;
    cef_browser_t *browser;
    cef_window_handle_t view;
    cef_request_context_t *request_context;
    int browser_id;
    char current_url[2048];
    char title[1024];
    char status_message[1024];
    int is_loading;
    int http_status;
    double loading_progress;
    int destroy_requested;
};

static cef_frame_t *main_frame_for_browser(gsde_chromium_browser_t *browser);

static gsde_chromium_browser_t *browser_from_client(cef_client_t *client) {
    return (gsde_chromium_browser_t *)((char *)client - offsetof(gsde_chromium_browser_t, client));
}

static gsde_chromium_browser_t *browser_from_life_span(cef_life_span_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, life_span_handler));
}

static gsde_chromium_browser_t *browser_from_load_handler(cef_load_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, load_handler));
}

static gsde_chromium_browser_t *browser_from_display_handler(cef_display_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, display_handler));
}

static gsde_chromium_browser_t *browser_from_context_menu_handler(cef_context_menu_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, context_menu_handler));
}

static gsde_chromium_browser_t *browser_from_download_handler(cef_download_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, download_handler));
}

static gsde_chromium_browser_t *browser_from_find_handler(cef_find_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, find_handler));
}

static gsde_chromium_browser_t *browser_from_permission_handler(cef_permission_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, permission_handler));
}

static gsde_chromium_browser_t *browser_from_request_handler(cef_request_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, request_handler));
}

static gsde_chromium_browser_t *browser_from_client_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, client));
}

static gsde_chromium_browser_t *browser_from_life_span_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, life_span_handler));
}

static gsde_chromium_browser_t *browser_from_load_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, load_handler));
}

static gsde_chromium_browser_t *browser_from_display_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, display_handler));
}

static gsde_chromium_browser_t *browser_from_context_menu_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, context_menu_handler));
}

static gsde_chromium_browser_t *browser_from_download_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, download_handler));
}

static gsde_chromium_browser_t *browser_from_find_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, find_handler));
}

static gsde_chromium_browser_t *browser_from_permission_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, permission_handler));
}

static gsde_chromium_browser_t *browser_from_request_base(cef_base_ref_counted_t *base) {
    return (gsde_chromium_browser_t *)((char *)base - offsetof(gsde_chromium_browser_t, request_handler));
}

static void CEF_CALLBACK gsde_client_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_client_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_client_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_client_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_client_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_client_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_client_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_client_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_life_span_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_life_span_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_life_span_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_life_span_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_life_span_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_life_span_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_life_span_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_life_span_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_load_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_load_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_load_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_load_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_load_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_load_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_load_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_load_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_display_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_display_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_display_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_display_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_display_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_display_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_display_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_display_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_context_menu_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_context_menu_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_context_menu_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_context_menu_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_context_menu_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_context_menu_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_context_menu_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_context_menu_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_download_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_download_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_download_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_download_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_download_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_download_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_download_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_download_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_find_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_find_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_find_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_find_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_find_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_find_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_find_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_find_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_permission_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_permission_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_permission_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_permission_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_permission_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_permission_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_permission_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_permission_base(base)->ref_count) >= 1;
}

static void CEF_CALLBACK gsde_request_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add(&browser_from_request_base(base)->ref_count, 1);
}

static int CEF_CALLBACK gsde_request_release(cef_base_ref_counted_t *base) {
    return atomic_fetch_sub(&browser_from_request_base(base)->ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_request_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_request_base(base)->ref_count) == 1;
}

static int CEF_CALLBACK gsde_request_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load(&browser_from_request_base(base)->ref_count) >= 1;
}

static cef_life_span_handler_t *CEF_CALLBACK gsde_get_life_span_handler(cef_client_t *client) {
    return &browser_from_client(client)->life_span_handler;
}

static cef_load_handler_t *CEF_CALLBACK gsde_get_load_handler(cef_client_t *client) {
    return &browser_from_client(client)->load_handler;
}

static cef_display_handler_t *CEF_CALLBACK gsde_get_display_handler(cef_client_t *client) {
    return &browser_from_client(client)->display_handler;
}

static cef_context_menu_handler_t *CEF_CALLBACK gsde_get_context_menu_handler(cef_client_t *client) {
    return &browser_from_client(client)->context_menu_handler;
}

static cef_download_handler_t *CEF_CALLBACK gsde_get_download_handler(cef_client_t *client) {
    return &browser_from_client(client)->download_handler;
}

static cef_find_handler_t *CEF_CALLBACK gsde_get_find_handler(cef_client_t *client) {
    return &browser_from_client(client)->find_handler;
}

static cef_permission_handler_t *CEF_CALLBACK gsde_get_permission_handler(cef_client_t *client) {
    return &browser_from_client(client)->permission_handler;
}

static cef_request_handler_t *CEF_CALLBACK gsde_get_request_handler(cef_client_t *client) {
    return &browser_from_client(client)->request_handler;
}

static void CEF_CALLBACK gsde_on_after_created(cef_life_span_handler_t *self, cef_browser_t *cef_browser) {
    gsde_chromium_browser_t *browser = browser_from_life_span(self);
    browser->browser = cef_browser;
    atomic_fetch_add(&live_browser_count, 1);
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d on_after_created", browser->browser_id);
    gsde_log(message);
    log_live_browser_count("after create");
    if (browser->browser && browser->browser->base.add_ref) browser->browser->base.add_ref((cef_base_ref_counted_t *)browser->browser);
}

static int CEF_CALLBACK gsde_do_close(cef_life_span_handler_t *self, cef_browser_t *cef_browser) {
    gsde_chromium_browser_t *browser = browser_from_life_span(self);
    (void)cef_browser;
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d do_close", browser->browser_id);
    gsde_log(message);
    return 0;
}

static void free_chromium_browser(gsde_chromium_browser_t *browser) {
    delete browser;
}

static void CEF_CALLBACK gsde_on_before_close(cef_life_span_handler_t *self, cef_browser_t *cef_browser) {
    gsde_chromium_browser_t *browser = browser_from_life_span(self);
    cef_browser_t *closed_browser = browser->browser ? browser->browser : cef_browser;
    browser->browser = NULL;
    int previous = atomic_fetch_sub(&live_browser_count, 1);
    if (previous <= 0) atomic_store(&live_browser_count, 0);
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d on_before_close", browser->browser_id);
    gsde_log(message);
    log_live_browser_count("after close");
    if (closed_browser && closed_browser->base.release) {
        closed_browser->base.release((cef_base_ref_counted_t *)closed_browser);
    }
}

static void copy_cef_string_to_buffer(const cef_string_t *cef_string, char *buffer, size_t buffer_size) {
    if (!buffer || buffer_size == 0) return;
    buffer[0] = '\0';
    if (!cef_string || !cef_string->str || cef_string->length == 0 || !cef_string_utf16_to_utf8_ptr || !cef_string_utf8_clear_ptr) return;

    cef_string_utf8_t utf8;
    memset(&utf8, 0, sizeof(utf8));
    if (cef_string_utf16_to_utf8_ptr(cef_string->str, cef_string->length, &utf8)) {
        snprintf(buffer, buffer_size, "%.*s", (int)utf8.length, utf8.str ? utf8.str : "");
        cef_string_utf8_clear_ptr(&utf8);
    }
}

static void update_browser_url_from_frame(gsde_chromium_browser_t *browser, cef_frame_t *frame) {
    if (!browser || !frame || !frame->get_url || !cef_string_userfree_utf16_free_ptr) return;
    cef_string_userfree_t cef_url = frame->get_url(frame);
    if (!cef_url) return;
    copy_cef_string_to_buffer(cef_url, browser->current_url, sizeof(browser->current_url));
    cef_string_userfree_utf16_free_ptr(cef_url);
}

static void load_url_in_cef_browser(cef_browser_t *cef_browser, const cef_string_t *url) {
    if (!cef_browser || !url) return;
    cef_frame_t *frame = cef_browser->get_main_frame ? cef_browser->get_main_frame(cef_browser) : NULL;
    if (!frame) return;
    frame->load_url(frame, url);
    if (frame->base.release) frame->base.release((cef_base_ref_counted_t *)frame);
}

static int CEF_CALLBACK gsde_on_before_popup(
    cef_life_span_handler_t *self,
    cef_browser_t *cef_browser,
    cef_frame_t *frame,
    int popup_id,
    const cef_string_t *target_url,
    const cef_string_t *target_frame_name,
    cef_window_open_disposition_t target_disposition,
    int user_gesture,
    const cef_popup_features_t *popupFeatures,
    cef_window_info_t *windowInfo,
    cef_client_t **client,
    cef_browser_settings_t *settings,
    cef_dictionary_value_t **extra_info,
    int *no_javascript_access
) {
    (void)frame; (void)popup_id; (void)target_frame_name; (void)target_disposition; (void)user_gesture; (void)popupFeatures; (void)windowInfo; (void)client; (void)settings; (void)extra_info; (void)no_javascript_access;
    gsde_chromium_browser_t *browser = browser_from_life_span(self);
    if (target_url && target_url->str && target_url->length > 0) {
        copy_cef_string_to_buffer(target_url, browser->current_url, sizeof(browser->current_url));
        load_url_in_cef_browser(cef_browser, target_url);
        char message[128];
        snprintf(message, sizeof(message), "CEF browser #%d opened popup in same pane", browser->browser_id);
        gsde_log(message);
    }
    return 1;
}

static void CEF_CALLBACK gsde_on_loading_state_change(cef_load_handler_t *self, cef_browser_t *cef_browser, int isLoading, int canGoBack, int canGoForward) {
    (void)cef_browser; (void)canGoBack; (void)canGoForward;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->is_loading = isLoading ? 1 : 0;
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d load state: %s", browser->browser_id, isLoading ? "loading" : "idle");
    gsde_log(message);
}

static void CEF_CALLBACK gsde_on_load_start(cef_load_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame, cef_transition_type_t transition_type) {
    (void)cef_browser; (void)transition_type;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->http_status = 0;
    update_browser_url_from_frame(browser, frame);
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d load start", browser->browser_id);
    gsde_log(message);
}

static void CEF_CALLBACK gsde_on_load_end(cef_load_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame, int httpStatusCode) {
    (void)cef_browser;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->http_status = httpStatusCode;
    update_browser_url_from_frame(browser, frame);
    char message[2300];
    snprintf(message, sizeof(message), "CEF browser #%d load end: HTTP %d URL %s", browser->browser_id, httpStatusCode, browser->current_url);
    gsde_log(message);
}

static void CEF_CALLBACK gsde_on_load_error(cef_load_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame, cef_errorcode_t errorCode, const cef_string_t *errorText, const cef_string_t *failedUrl) {
    (void)cef_browser; (void)errorText; (void)failedUrl;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->http_status = (int)errorCode;
    update_browser_url_from_frame(browser, frame);
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d load error: %d", browser->browser_id, errorCode);
    gsde_log(message);
}

static void CEF_CALLBACK gsde_on_address_change(cef_display_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame, const cef_string_t *url) {
    (void)cef_browser; (void)frame;
    gsde_chromium_browser_t *browser = browser_from_display_handler(self);
    copy_cef_string_to_buffer(url, browser->current_url, sizeof(browser->current_url));
}

static void CEF_CALLBACK gsde_on_title_change(cef_display_handler_t *self, cef_browser_t *cef_browser, const cef_string_t *title) {
    (void)cef_browser;
    gsde_chromium_browser_t *browser = browser_from_display_handler(self);
    copy_cef_string_to_buffer(title, browser->title, sizeof(browser->title));
}

static void CEF_CALLBACK gsde_on_status_message(cef_display_handler_t *self, cef_browser_t *cef_browser, const cef_string_t *value) {
    (void)cef_browser;
    gsde_chromium_browser_t *browser = browser_from_display_handler(self);
    copy_cef_string_to_buffer(value, browser->status_message, sizeof(browser->status_message));
}

static void CEF_CALLBACK gsde_on_loading_progress_change(cef_display_handler_t *self, cef_browser_t *cef_browser, double progress) {
    (void)cef_browser;
    gsde_chromium_browser_t *browser = browser_from_display_handler(self);
    browser->loading_progress = progress;
}

static int CEF_CALLBACK gsde_run_context_menu(
    cef_context_menu_handler_t *self,
    cef_browser_t *cef_browser,
    cef_frame_t *frame,
    cef_context_menu_params_t *params,
    cef_menu_model_t *model,
    cef_run_context_menu_callback_t *callback
) {
    (void)cef_browser; (void)frame; (void)params; (void)model;
    gsde_chromium_browser_t *browser = browser_from_context_menu_handler(self);
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d context menu suppressed", browser->browser_id);
    gsde_log(message);
    if (callback && callback->cancel) callback->cancel(callback);
    return 1;
}

static void CEF_CALLBACK gsde_on_context_menu_dismissed(cef_context_menu_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame) {
    (void)cef_browser; (void)frame;
    gsde_chromium_browser_t *browser = browser_from_context_menu_handler(self);
    char message[128];
    snprintf(message, sizeof(message), "CEF browser #%d context menu dismissed", browser->browser_id);
    gsde_log(message);
}

static int CEF_CALLBACK gsde_can_download(cef_download_handler_t *self, cef_browser_t *cef_browser, const cef_string_t *url, const cef_string_t *request_method) {
    (void)cef_browser; (void)request_method;
    gsde_chromium_browser_t *browser = browser_from_download_handler(self);
    char url_buffer[512];
    copy_cef_string_to_buffer(url, url_buffer, sizeof(url_buffer));
    char message[768];
    snprintf(message, sizeof(message), "CEF browser #%d allowing download: %s", browser->browser_id, url_buffer);
    snprintf(browser->status_message, sizeof(browser->status_message), "Download requested…");
    gsde_log(message);
    return 1;
}

static int CEF_CALLBACK gsde_on_before_download(
    cef_download_handler_t *self,
    cef_browser_t *cef_browser,
    cef_download_item_t *download_item,
    const cef_string_t *suggested_name,
    cef_before_download_callback_t *callback
) {
    (void)cef_browser; (void)download_item;
    gsde_chromium_browser_t *browser = browser_from_download_handler(self);
    char name_buffer[256];
    copy_cef_string_to_buffer(suggested_name, name_buffer, sizeof(name_buffer));
    char message[512];
    snprintf(message, sizeof(message), "CEF browser #%d starting download: %s", browser->browser_id, name_buffer[0] ? name_buffer : "(unnamed)");
    snprintf(browser->status_message, sizeof(browser->status_message), "Downloading %s…", name_buffer[0] ? name_buffer : "file");
    gsde_log(message);
    if (callback && callback->cont) {
        cef_string_t empty_path;
        memset(&empty_path, 0, sizeof(empty_path));
        callback->cont(callback, &empty_path, 1);
    }
    return 1;
}

static void CEF_CALLBACK gsde_on_download_updated(
    cef_download_handler_t *self,
    cef_browser_t *cef_browser,
    cef_download_item_t *download_item,
    cef_download_item_callback_t *callback
) {
    (void)cef_browser; (void)callback;
    gsde_chromium_browser_t *browser = browser_from_download_handler(self);
    if (!download_item) return;
    if (download_item->is_complete && download_item->is_complete(download_item)) {
        char message[128];
        snprintf(message, sizeof(message), "CEF browser #%d download complete", browser->browser_id);
        snprintf(browser->status_message, sizeof(browser->status_message), "Download complete");
        gsde_log(message);
    } else if (download_item->is_canceled && download_item->is_canceled(download_item)) {
        char message[128];
        snprintf(message, sizeof(message), "CEF browser #%d download canceled", browser->browser_id);
        snprintf(browser->status_message, sizeof(browser->status_message), "Download canceled");
        gsde_log(message);
    } else if (download_item->is_in_progress && download_item->is_in_progress(download_item)) {
        int percent = download_item->get_percent_complete ? download_item->get_percent_complete(download_item) : -1;
        int64_t received = download_item->get_received_bytes ? download_item->get_received_bytes(download_item) : 0;
        int64_t total = download_item->get_total_bytes ? download_item->get_total_bytes(download_item) : 0;
        if (percent >= 0) {
            snprintf(browser->status_message, sizeof(browser->status_message), "Downloading… %d%%", percent);
        } else if (total > 0) {
            snprintf(browser->status_message, sizeof(browser->status_message), "Downloading… %lld / %lld bytes", (long long)received, (long long)total);
        } else {
            snprintf(browser->status_message, sizeof(browser->status_message), "Downloading… %lld bytes", (long long)received);
        }
    }
}

static void CEF_CALLBACK gsde_on_find_result(
    cef_find_handler_t *self,
    cef_browser_t *cef_browser,
    int identifier,
    int count,
    const cef_rect_t *selectionRect,
    int activeMatchOrdinal,
    int finalUpdate
) {
    (void)cef_browser; (void)identifier; (void)selectionRect;
    gsde_chromium_browser_t *browser = browser_from_find_handler(self);
    if (count <= 0) {
        snprintf(browser->status_message, sizeof(browser->status_message), finalUpdate ? "No find results" : "Finding…");
    } else {
        snprintf(browser->status_message, sizeof(browser->status_message), "Find: %d of %d", activeMatchOrdinal, count);
    }
}

static int CEF_CALLBACK gsde_on_request_media_access_permission(
    cef_permission_handler_t *self,
    cef_browser_t *cef_browser,
    cef_frame_t *frame,
    const cef_string_t *requesting_origin,
    uint32_t requested_permissions,
    cef_media_access_callback_t *callback
) {
    (void)cef_browser; (void)frame;
    gsde_chromium_browser_t *browser = browser_from_permission_handler(self);
    char origin_buffer[512];
    copy_cef_string_to_buffer(requesting_origin, origin_buffer, sizeof(origin_buffer));
    char message[768];
    snprintf(message, sizeof(message), "CEF browser #%d denied media permission from %s (%u)", browser->browser_id, origin_buffer, requested_permissions);
    snprintf(browser->status_message, sizeof(browser->status_message), "Media permission denied");
    gsde_log(message);
    if (callback && callback->cancel) callback->cancel(callback);
    return 1;
}

static int CEF_CALLBACK gsde_on_show_permission_prompt(
    cef_permission_handler_t *self,
    cef_browser_t *cef_browser,
    uint64_t prompt_id,
    const cef_string_t *requesting_origin,
    uint32_t requested_permissions,
    cef_permission_prompt_callback_t *callback
) {
    (void)cef_browser;
    gsde_chromium_browser_t *browser = browser_from_permission_handler(self);
    char origin_buffer[512];
    copy_cef_string_to_buffer(requesting_origin, origin_buffer, sizeof(origin_buffer));
    char message[768];
    snprintf(message, sizeof(message), "CEF browser #%d denied permission prompt %llu from %s (%u)", browser->browser_id, (unsigned long long)prompt_id, origin_buffer, requested_permissions);
    snprintf(browser->status_message, sizeof(browser->status_message), "Permission denied");
    gsde_log(message);
    if (callback && callback->cont) callback->cont(callback, CEF_PERMISSION_RESULT_DENY);
    return 1;
}

static void CEF_CALLBACK gsde_on_dismiss_permission_prompt(
    cef_permission_handler_t *self,
    cef_browser_t *cef_browser,
    uint64_t prompt_id,
    cef_permission_request_result_t result
) {
    (void)cef_browser;
    gsde_chromium_browser_t *browser = browser_from_permission_handler(self);
    char message[160];
    snprintf(message, sizeof(message), "CEF browser #%d permission prompt %llu dismissed: %d", browser->browser_id, (unsigned long long)prompt_id, result);
    gsde_log(message);
}

static int CEF_CALLBACK gsde_get_auth_credentials(
    cef_request_handler_t *self,
    cef_browser_t *cef_browser,
    const cef_string_t *origin_url,
    int isProxy,
    const cef_string_t *host,
    int port,
    const cef_string_t *realm,
    const cef_string_t *scheme,
    cef_auth_callback_t *callback
) {
    (void)cef_browser; (void)isProxy; (void)port; (void)realm; (void)scheme; (void)callback;
    gsde_chromium_browser_t *browser = browser_from_request_handler(self);
    char origin_buffer[512];
    char host_buffer[256];
    copy_cef_string_to_buffer(origin_url, origin_buffer, sizeof(origin_buffer));
    copy_cef_string_to_buffer(host, host_buffer, sizeof(host_buffer));
    char message[900];
    snprintf(message, sizeof(message), "CEF browser #%d canceled auth request for %s (%s)", browser->browser_id, origin_buffer, host_buffer);
    snprintf(browser->status_message, sizeof(browser->status_message), "Authentication canceled");
    gsde_log(message);
    return 0;
}

static int CEF_CALLBACK gsde_on_certificate_error(
    cef_request_handler_t *self,
    cef_browser_t *cef_browser,
    cef_errorcode_t cert_error,
    const cef_string_t *request_url,
    cef_sslinfo_t *ssl_info,
    cef_callback_t *callback
) {
    (void)cef_browser; (void)ssl_info;
    gsde_chromium_browser_t *browser = browser_from_request_handler(self);
    char url_buffer[512];
    copy_cef_string_to_buffer(request_url, url_buffer, sizeof(url_buffer));
    char message[900];
    snprintf(message, sizeof(message), "CEF browser #%d canceled certificate error %d for %s", browser->browser_id, cert_error, url_buffer);
    snprintf(browser->status_message, sizeof(browser->status_message), "Certificate error canceled");
    gsde_log(message);
    if (callback && callback->cancel) callback->cancel(callback);
    return 1;
}

static void setup_client_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_client_add_ref;
    base->release = gsde_client_release;
    base->has_one_ref = gsde_client_has_one_ref;
    base->has_at_least_one_ref = gsde_client_has_at_least_one_ref;
}

static void setup_life_span_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_life_span_add_ref;
    base->release = gsde_life_span_release;
    base->has_one_ref = gsde_life_span_has_one_ref;
    base->has_at_least_one_ref = gsde_life_span_has_at_least_one_ref;
}

static void setup_load_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_load_add_ref;
    base->release = gsde_load_release;
    base->has_one_ref = gsde_load_has_one_ref;
    base->has_at_least_one_ref = gsde_load_has_at_least_one_ref;
}

static void setup_display_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_display_add_ref;
    base->release = gsde_display_release;
    base->has_one_ref = gsde_display_has_one_ref;
    base->has_at_least_one_ref = gsde_display_has_at_least_one_ref;
}

static void setup_context_menu_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_context_menu_add_ref;
    base->release = gsde_context_menu_release;
    base->has_one_ref = gsde_context_menu_has_one_ref;
    base->has_at_least_one_ref = gsde_context_menu_has_at_least_one_ref;
}

static void setup_download_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_download_add_ref;
    base->release = gsde_download_release;
    base->has_one_ref = gsde_download_has_one_ref;
    base->has_at_least_one_ref = gsde_download_has_at_least_one_ref;
}

static void setup_find_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_find_add_ref;
    base->release = gsde_find_release;
    base->has_one_ref = gsde_find_has_one_ref;
    base->has_at_least_one_ref = gsde_find_has_at_least_one_ref;
}

static void setup_permission_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_permission_add_ref;
    base->release = gsde_permission_release;
    base->has_one_ref = gsde_permission_has_one_ref;
    base->has_at_least_one_ref = gsde_permission_has_at_least_one_ref;
}

static void setup_request_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = gsde_request_add_ref;
    base->release = gsde_request_release;
    base->has_one_ref = gsde_request_has_one_ref;
    base->has_at_least_one_ref = gsde_request_has_at_least_one_ref;
}

static void set_cef_string(const char *utf8, cef_string_t *out) {
    if (utf8 && utf8[0] != '\0') cef_string_utf8_to_utf16_ptr(utf8, strlen(utf8), out);
}

class ScopedCefString {
public:
    explicit ScopedCefString(const char *utf8) {
        memset(&value_, 0, sizeof(value_));
        set_cef_string(utf8, &value_);
    }

    ~ScopedCefString() {
        cef_string_utf16_clear_ptr(&value_);
    }

    ScopedCefString(const ScopedCefString &) = delete;
    ScopedCefString &operator=(const ScopedCefString &) = delete;

    cef_string_t *get() { return &value_; }
    const cef_string_t *get() const { return &value_; }

private:
    cef_string_t value_;
};

template <typename T>
class ScopedCefRef {
public:
    explicit ScopedCefRef(T *ptr) : ptr_(ptr) {}
    ~ScopedCefRef() { reset(nullptr); }

    ScopedCefRef(const ScopedCefRef &) = delete;
    ScopedCefRef &operator=(const ScopedCefRef &) = delete;

    T *get() const { return ptr_; }
    T *operator->() const { return ptr_; }
    explicit operator bool() const { return ptr_ != nullptr; }

    T *release() {
        T *ptr = ptr_;
        ptr_ = nullptr;
        return ptr;
    }

    void reset(T *ptr) {
        if (ptr_ && ptr_->base.release) {
            ptr_->base.release((cef_base_ref_counted_t *)ptr_);
        }
        ptr_ = ptr;
    }

private:
    T *ptr_;
};

class ScopedCefUserFreeString {
public:
    explicit ScopedCefUserFreeString(cef_string_userfree_t value) : value_(value) {}
    ~ScopedCefUserFreeString() {
        if (value_ && cef_string_userfree_utf16_free_ptr) cef_string_userfree_utf16_free_ptr(value_);
    }

    ScopedCefUserFreeString(const ScopedCefUserFreeString &) = delete;
    ScopedCefUserFreeString &operator=(const ScopedCefUserFreeString &) = delete;

    cef_string_userfree_t get() const { return value_; }
    explicit operator bool() const { return value_ != nullptr; }

private:
    cef_string_userfree_t value_;
};

static cef_app_t global_cef_app;
static atomic_int global_cef_app_ref_count{1};

static void CEF_CALLBACK gsde_app_add_ref(cef_base_ref_counted_t *base) {
    (void)base;
    atomic_fetch_add(&global_cef_app_ref_count, 1);
}

static int CEF_CALLBACK gsde_app_release(cef_base_ref_counted_t *base) {
    (void)base;
    return atomic_fetch_sub(&global_cef_app_ref_count, 1) == 1;
}

static int CEF_CALLBACK gsde_app_has_one_ref(cef_base_ref_counted_t *base) {
    (void)base;
    return atomic_load(&global_cef_app_ref_count) == 1;
}

static int CEF_CALLBACK gsde_app_has_at_least_one_ref(cef_base_ref_counted_t *base) {
    (void)base;
    return atomic_load(&global_cef_app_ref_count) >= 1;
}

static void append_switch(cef_command_line_t *command_line, const char *name) {
    if (!command_line || !command_line->append_switch || !name) return;
    ScopedCefString cef_name(name);
    command_line->append_switch(command_line, cef_name.get());
}

static void CEF_CALLBACK gsde_on_before_command_line_processing(cef_app_t *self, const cef_string_t *process_type, cef_command_line_t *command_line) {
    (void)self;
    if (process_type && process_type->length > 0) return;
    append_switch(command_line, "use-mock-keychain");
    append_switch(command_line, "disable-component-update");
    append_switch(command_line, "disable-background-networking");
}

static cef_app_t *gsde_cef_app(void) {
    static bool configured = false;
    if (!configured) {
        memset(&global_cef_app, 0, sizeof(global_cef_app));
        global_cef_app.base.size = sizeof(global_cef_app);
        global_cef_app.base.add_ref = gsde_app_add_ref;
        global_cef_app.base.release = gsde_app_release;
        global_cef_app.base.has_one_ref = gsde_app_has_one_ref;
        global_cef_app.base.has_at_least_one_ref = gsde_app_has_at_least_one_ref;
        global_cef_app.on_before_command_line_processing = gsde_on_before_command_line_processing;
        configured = true;
    }
    return &global_cef_app;
}
static void configure_browser_handlers(gsde_chromium_browser_t *browser) {
    setup_client_base(&browser->client.base, sizeof(browser->client));
    setup_life_span_base(&browser->life_span_handler.base, sizeof(browser->life_span_handler));
    setup_load_base(&browser->load_handler.base, sizeof(browser->load_handler));
    setup_display_base(&browser->display_handler.base, sizeof(browser->display_handler));
    setup_context_menu_base(&browser->context_menu_handler.base, sizeof(browser->context_menu_handler));
    setup_download_base(&browser->download_handler.base, sizeof(browser->download_handler));
    setup_find_base(&browser->find_handler.base, sizeof(browser->find_handler));
    setup_permission_base(&browser->permission_handler.base, sizeof(browser->permission_handler));
    setup_request_base(&browser->request_handler.base, sizeof(browser->request_handler));

    browser->client.get_life_span_handler = gsde_get_life_span_handler;
    browser->client.get_load_handler = gsde_get_load_handler;
    browser->client.get_display_handler = gsde_get_display_handler;
    browser->client.get_context_menu_handler = gsde_get_context_menu_handler;
    browser->client.get_download_handler = gsde_get_download_handler;
    browser->client.get_find_handler = gsde_get_find_handler;
    browser->client.get_permission_handler = gsde_get_permission_handler;
    browser->client.get_request_handler = gsde_get_request_handler;
    browser->life_span_handler.on_before_popup = gsde_on_before_popup;
    browser->life_span_handler.on_after_created = gsde_on_after_created;
    browser->life_span_handler.do_close = gsde_do_close;
    browser->life_span_handler.on_before_close = gsde_on_before_close;
    browser->load_handler.on_loading_state_change = gsde_on_loading_state_change;
    browser->load_handler.on_load_start = gsde_on_load_start;
    browser->load_handler.on_load_end = gsde_on_load_end;
    browser->load_handler.on_load_error = gsde_on_load_error;
    browser->display_handler.on_address_change = gsde_on_address_change;
    browser->display_handler.on_title_change = gsde_on_title_change;
    browser->display_handler.on_status_message = gsde_on_status_message;
    browser->display_handler.on_loading_progress_change = gsde_on_loading_progress_change;
    browser->context_menu_handler.run_context_menu = gsde_run_context_menu;
    browser->context_menu_handler.on_context_menu_dismissed = gsde_on_context_menu_dismissed;
    browser->download_handler.can_download = gsde_can_download;
    browser->download_handler.on_before_download = gsde_on_before_download;
    browser->download_handler.on_download_updated = gsde_on_download_updated;
    browser->find_handler.on_find_result = gsde_on_find_result;
    browser->permission_handler.on_request_media_access_permission = gsde_on_request_media_access_permission;
    browser->permission_handler.on_show_permission_prompt = gsde_on_show_permission_prompt;
    browser->permission_handler.on_dismiss_permission_prompt = gsde_on_dismiss_permission_prompt;
    browser->request_handler.get_auth_credentials = gsde_get_auth_credentials;
    browser->request_handler.on_certificate_error = gsde_on_certificate_error;
}
#endif

gsde_chromium_browser_t *gsde_chromium_browser_create(void *parent_nsview, int width, int height, const char *initial_url, const char *cache_path) {
#if GSDE_HAVE_CEF_HEADERS
    if (!initialized || !parent_nsview) {
        set_last_error(!initialized ? "CEF browser create skipped: CEF is not initialized" : "CEF browser create skipped: parent NSView is null");
        return NULL;
    }
    gsde_log("creating CEF browser");

    gsde_chromium_browser_t *browser = new (std::nothrow) gsde_chromium_browser_t();
    if (!browser) return NULL;
    browser->browser_id = atomic_fetch_add(&next_browser_id, 1);
    snprintf(browser->current_url, sizeof(browser->current_url), "%s", initial_url ? initial_url : "about:blank");
    configure_browser_handlers(browser);

    if (cache_path && cache_path[0] != '\0') {
        gsde_log("per-browser CEF cache paths are disabled; using global request context");
    }

    cef_window_info_t window_info;
    memset(&window_info, 0, sizeof(window_info));
    window_info.size = sizeof(window_info);
    window_info.parent_view = parent_nsview;
    window_info.bounds.x = 0;
    window_info.bounds.y = 0;
    window_info.bounds.width = width;
    window_info.bounds.height = height;

    cef_browser_settings_t browser_settings;
    memset(&browser_settings, 0, sizeof(browser_settings));
    browser_settings.size = sizeof(browser_settings);

    ScopedCefString url(initial_url ? initial_url : "about:blank");

    browser->browser = cef_browser_host_create_browser_sync_ptr(&window_info, &browser->client, url.get(), &browser_settings, NULL, browser->request_context);
    browser->view = window_info.view;

    if (!browser->browser) {
        set_last_error("cef_browser_host_create_browser_sync returned NULL");
        gsde_chromium_browser_destroy(browser);
        return NULL;
    }
    cef_browser_host_t *created_host = browser->browser->get_host ? browser->browser->get_host(browser->browser) : NULL;
    if (!browser->view && created_host && created_host->get_window_handle) {
        browser->view = created_host->get_window_handle(created_host);
    }

    snprintf(status, sizeof(status), "CEF browser created%s", browser->view ? " with native view" : " without native view");
    snprintf(last_error, sizeof(last_error), "No CEF errors recorded");
    char created_message[160];
    snprintf(created_message, sizeof(created_message), "CEF browser #%d created%s", browser->browser_id, browser->view ? " with native view" : " without native view");
    gsde_log(created_message);
    if (browser->browser->base.add_ref) browser->browser->base.add_ref((cef_base_ref_counted_t *)browser->browser);
    return browser;
#else
    (void)parent_nsview; (void)width; (void)height; (void)initial_url; (void)cache_path;
    return NULL;
#endif
}

void *gsde_chromium_browser_view(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    return browser ? browser->view : NULL;
#else
    (void)browser;
    return NULL;
#endif
}

void gsde_chromium_browser_destroy(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser) return;
    browser->destroy_requested = 1;
    if (browser->browser) {
        cef_browser_host_t *host = browser->browser->get_host ? browser->browser->get_host(browser->browser) : NULL;
        if (host && host->close_browser) {
            host->close_browser(host, 0);
            return;
        }
    }
    free_chromium_browser(browser);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_resize(gsde_chromium_browser_t *browser, int width, int height) {
#if GSDE_HAVE_CEF_HEADERS
    (void)width; (void)height;
    if (!browser || !browser->browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (host && host->was_resized) host->was_resized(host);
#else
    (void)browser; (void)width; (void)height;
#endif
}

const char *gsde_chromium_browser_current_url(gsde_chromium_browser_t *browser) {
    return browser ? browser->current_url : "";
}

const char *gsde_chromium_browser_title(gsde_chromium_browser_t *browser) {
    return browser ? browser->title : "";
}

const char *gsde_chromium_browser_status_message(gsde_chromium_browser_t *browser) {
    return browser ? browser->status_message : "";
}

int gsde_chromium_browser_is_loading(gsde_chromium_browser_t *browser) {
    return browser ? browser->is_loading : 0;
}

int gsde_chromium_browser_http_status(gsde_chromium_browser_t *browser) {
    return browser ? browser->http_status : 0;
}

double gsde_chromium_browser_loading_progress(gsde_chromium_browser_t *browser) {
    return browser ? browser->loading_progress : 0.0;
}

void gsde_chromium_browser_load_url(gsde_chromium_browser_t *browser, const char *url) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser || !url) return;
    snprintf(browser->current_url, sizeof(browser->current_url), "%s", url);
    ScopedCefRef<cef_frame_t> frame(main_frame_for_browser(browser));
    if (!frame) return;
    ScopedCefString cef_url(url);
    frame->load_url(frame.get(), cef_url.get());
#else
    (void)browser; (void)url;
#endif
}

int gsde_chromium_browser_can_go_back(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    return (browser && browser->browser && browser->browser->can_go_back(browser->browser)) ? 1 : 0;
#else
    (void)browser;
    return 0;
#endif
}

int gsde_chromium_browser_can_go_forward(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    return (browser && browser->browser && browser->browser->can_go_forward(browser->browser)) ? 1 : 0;
#else
    (void)browser;
    return 0;
#endif
}

void gsde_chromium_browser_go_back(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (browser && browser->browser && browser->browser->can_go_back(browser->browser)) browser->browser->go_back(browser->browser);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_go_forward(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (browser && browser->browser && browser->browser->can_go_forward(browser->browser)) browser->browser->go_forward(browser->browser);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_reload(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (browser && browser->browser) browser->browser->reload(browser->browser);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_reload_ignore_cache(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (browser && browser->browser) browser->browser->reload_ignore_cache(browser->browser);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_stop(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (browser && browser->browser) browser->browser->stop_load(browser->browser);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_find(gsde_chromium_browser_t *browser, const char *query, int forward, int match_case, int find_next) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (!host || !host->find) return;
    ScopedCefString cef_query(query && query[0] != '\0' ? query : NULL);
    host->find(host, query && query[0] != '\0' ? cef_query.get() : NULL, forward ? 1 : 0, match_case ? 1 : 0, find_next ? 1 : 0);
#else
    (void)browser; (void)query; (void)forward; (void)match_case; (void)find_next;
#endif
}

void gsde_chromium_browser_stop_finding(gsde_chromium_browser_t *browser, int clear_selection) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (host && host->stop_finding) host->stop_finding(host, clear_selection ? 1 : 0);
#else
    (void)browser; (void)clear_selection;
#endif
}

static void gsde_chromium_browser_zoom(gsde_chromium_browser_t *browser, cef_zoom_command_t command) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (host && host->zoom) host->zoom(host, command);
#else
    (void)browser; (void)command;
#endif
}

void gsde_chromium_browser_zoom_in(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    gsde_chromium_browser_zoom(browser, CEF_ZOOM_COMMAND_IN);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_zoom_out(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    gsde_chromium_browser_zoom(browser, CEF_ZOOM_COMMAND_OUT);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_zoom_reset(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    gsde_chromium_browser_zoom(browser, CEF_ZOOM_COMMAND_RESET);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_print(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (host && host->print) host->print(host);
#else
    (void)browser;
#endif
}

static cef_frame_t *main_frame_for_browser(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser || !browser->browser->get_main_frame) return NULL;
    return browser->browser->get_main_frame(browser->browser);
#else
    (void)browser;
    return NULL;
#endif
}

#if GSDE_HAVE_CEF_HEADERS
static void with_main_frame(gsde_chromium_browser_t *browser, void (*action)(cef_frame_t *frame)) {
    ScopedCefRef<cef_frame_t> frame(main_frame_for_browser(browser));
    if (!frame) return;
    action(frame.get());
}

static void frame_cut(cef_frame_t *frame) { if (frame->cut) frame->cut(frame); }
static void frame_copy(cef_frame_t *frame) { if (frame->copy) frame->copy(frame); }
static void frame_paste(cef_frame_t *frame) { if (frame->paste) frame->paste(frame); }
static void frame_select_all(cef_frame_t *frame) { if (frame->select_all) frame->select_all(frame); }
static void frame_view_source(cef_frame_t *frame) { if (frame->view_source) frame->view_source(frame); }
#endif

void gsde_chromium_browser_cut(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    with_main_frame(browser, frame_cut);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_copy(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    with_main_frame(browser, frame_copy);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_paste(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    with_main_frame(browser, frame_paste);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_select_all(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    with_main_frame(browser, frame_select_all);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_view_source(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    with_main_frame(browser, frame_view_source);
#else
    (void)browser;
#endif
}

void gsde_chromium_browser_focus(gsde_chromium_browser_t *browser, int focused) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (host && host->set_focus) host->set_focus(host, focused ? 1 : 0);
#else
    (void)browser; (void)focused;
#endif
}

void gsde_chromium_browser_show_devtools(gsde_chromium_browser_t *browser) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (!host || !host->show_dev_tools) return;
    cef_window_info_t window_info;
    memset(&window_info, 0, sizeof(window_info));
    window_info.size = sizeof(window_info);
    cef_browser_settings_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.size = sizeof(settings);
    window_info.bounds.x = 120;
    window_info.bounds.y = 120;
    window_info.bounds.width = 1200;
    window_info.bounds.height = 800;
    host->show_dev_tools(host, &window_info, &browser->client, &settings, NULL);
#else
    (void)browser;
#endif
}
