#include "ChromiumStub.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if __has_include("include/capi/cef_app_capi.h")
#define GSDE_HAVE_CEF_HEADERS 1
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/internal/cef_string.h"
#else
#define GSDE_HAVE_CEF_HEADERS 0
#endif

static void *cef_handle = NULL;
static bool attempted_load = false;
static bool initialized = false;
static char status[512] = "WebKit fallback backend active; CEF has not been initialized";
static char last_error[512] = "No CEF errors recorded";

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
    snprintf(status, sizeof(status), "CEF framework found, but CEF headers were not available at compile time; using WebKit fallback");
    return false;
#endif
}

static bool cef_enabled_by_environment(void) {
    const char *enabled = getenv("GSDE_ENABLE_CEF");
    return enabled && strcmp(enabled, "1") == 0;
}

const char *gsde_chromium_backend_status(void) {
    if (!cef_enabled_by_environment()) {
        return "WebKit fallback backend active; set GSDE_ENABLE_CEF=1 to test CEF";
    }
    load_cef_framework();
    return status;
}

int gsde_chromium_cef_available(void) {
    if (!cef_enabled_by_environment()) return 0;
    return load_cef_framework() ? 1 : 0;
}

int gsde_chromium_execute_process(int argc, char **argv) {
#if GSDE_HAVE_CEF_HEADERS
    if (!load_cef_framework()) return -1;
    cef_main_args_t args = { .argc = argc, .argv = argv };
    return cef_execute_process_ptr(&args, NULL, NULL);
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

    cef_main_args_t args = {0};
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
        cef_string_utf8_to_utf16_ptr(cache_path, strlen(cache_path), &settings.cache_path);
    }
    if (browser_subprocess_path && browser_subprocess_path[0] != '\0') {
        cef_string_utf8_to_utf16_ptr(browser_subprocess_path, strlen(browser_subprocess_path), &settings.browser_subprocess_path);
    }

    gsde_log("calling cef_initialize");
    int ok = cef_initialize_ptr(&args, &settings, NULL, NULL);
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
    }
#endif
}

#if GSDE_HAVE_CEF_HEADERS
struct gsde_chromium_browser {
    cef_client_t client;
    cef_life_span_handler_t life_span_handler;
    cef_load_handler_t load_handler;
    atomic_int ref_count;
    cef_browser_t *browser;
    cef_window_handle_t view;
    cef_request_context_t *request_context;
    char current_url[2048];
    int is_loading;
    int http_status;
};

static gsde_chromium_browser_t *browser_from_client(cef_client_t *client) {
    return (gsde_chromium_browser_t *)((char *)client - offsetof(gsde_chromium_browser_t, client));
}

static gsde_chromium_browser_t *browser_from_life_span(cef_life_span_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, life_span_handler));
}

static gsde_chromium_browser_t *browser_from_load_handler(cef_load_handler_t *handler) {
    return (gsde_chromium_browser_t *)((char *)handler - offsetof(gsde_chromium_browser_t, load_handler));
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

static cef_life_span_handler_t *CEF_CALLBACK gsde_get_life_span_handler(cef_client_t *client) {
    return &browser_from_client(client)->life_span_handler;
}

static cef_load_handler_t *CEF_CALLBACK gsde_get_load_handler(cef_client_t *client) {
    return &browser_from_client(client)->load_handler;
}

static void CEF_CALLBACK gsde_on_after_created(cef_life_span_handler_t *self, cef_browser_t *cef_browser) {
    gsde_chromium_browser_t *browser = browser_from_life_span(self);
    browser->browser = cef_browser;
    gsde_log("CEF on_after_created");
    if (browser->browser && browser->browser->base.add_ref) browser->browser->base.add_ref((cef_base_ref_counted_t *)browser->browser);
}

static void update_browser_url_from_frame(gsde_chromium_browser_t *browser, cef_frame_t *frame) {
    if (!browser || !frame || !frame->get_url || !cef_string_utf16_to_utf8_ptr || !cef_string_utf8_clear_ptr || !cef_string_userfree_utf16_free_ptr) return;
    cef_string_userfree_t cef_url = frame->get_url(frame);
    if (!cef_url) return;

    cef_string_utf8_t utf8;
    memset(&utf8, 0, sizeof(utf8));
    if (cef_url->str && cef_url->length > 0 && cef_string_utf16_to_utf8_ptr(cef_url->str, cef_url->length, &utf8)) {
        snprintf(browser->current_url, sizeof(browser->current_url), "%.*s", (int)utf8.length, utf8.str ? utf8.str : "");
        cef_string_utf8_clear_ptr(&utf8);
    }
    cef_string_userfree_utf16_free_ptr(cef_url);
}

static void CEF_CALLBACK gsde_on_loading_state_change(cef_load_handler_t *self, cef_browser_t *cef_browser, int isLoading, int canGoBack, int canGoForward) {
    (void)cef_browser; (void)canGoBack; (void)canGoForward;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->is_loading = isLoading ? 1 : 0;
    gsde_log(isLoading ? "CEF load state: loading" : "CEF load state: idle");
}

static void CEF_CALLBACK gsde_on_load_start(cef_load_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame, cef_transition_type_t transition_type) {
    (void)cef_browser; (void)transition_type;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->http_status = 0;
    update_browser_url_from_frame(browser, frame);
    gsde_log("CEF load start");
}

static void CEF_CALLBACK gsde_on_load_end(cef_load_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame, int httpStatusCode) {
    (void)cef_browser;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->http_status = httpStatusCode;
    update_browser_url_from_frame(browser, frame);
    char message[128];
    snprintf(message, sizeof(message), "CEF load end: HTTP %d", httpStatusCode);
    gsde_log(message);
}

static void CEF_CALLBACK gsde_on_load_error(cef_load_handler_t *self, cef_browser_t *cef_browser, cef_frame_t *frame, cef_errorcode_t errorCode, const cef_string_t *errorText, const cef_string_t *failedUrl) {
    (void)cef_browser; (void)errorText; (void)failedUrl;
    gsde_chromium_browser_t *browser = browser_from_load_handler(self);
    browser->http_status = (int)errorCode;
    update_browser_url_from_frame(browser, frame);
    char message[128];
    snprintf(message, sizeof(message), "CEF load error: %d", errorCode);
    gsde_log(message);
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

static void set_cef_string(const char *utf8, cef_string_t *out) {
    if (utf8 && utf8[0] != '\0') cef_string_utf8_to_utf16_ptr(utf8, strlen(utf8), out);
}
#endif

gsde_chromium_browser_t *gsde_chromium_browser_create(void *parent_nsview, int width, int height, const char *initial_url, const char *cache_path) {
#if GSDE_HAVE_CEF_HEADERS
    if (!initialized || !parent_nsview) {
        set_last_error(!initialized ? "CEF browser create skipped: CEF is not initialized" : "CEF browser create skipped: parent NSView is null");
        return NULL;
    }
    gsde_log("creating CEF browser");

    gsde_chromium_browser_t *browser = calloc(1, sizeof(gsde_chromium_browser_t));
    if (!browser) return NULL;
    atomic_init(&browser->ref_count, 1);
    snprintf(browser->current_url, sizeof(browser->current_url), "%s", initial_url ? initial_url : "about:blank");

    setup_client_base(&browser->client.base, sizeof(browser->client));
    setup_life_span_base(&browser->life_span_handler.base, sizeof(browser->life_span_handler));
    setup_load_base(&browser->load_handler.base, sizeof(browser->load_handler));
    browser->client.get_life_span_handler = gsde_get_life_span_handler;
    browser->client.get_load_handler = gsde_get_load_handler;
    browser->life_span_handler.on_after_created = gsde_on_after_created;
    browser->load_handler.on_loading_state_change = gsde_on_loading_state_change;
    browser->load_handler.on_load_start = gsde_on_load_start;
    browser->load_handler.on_load_end = gsde_on_load_end;
    browser->load_handler.on_load_error = gsde_on_load_error;

    if (cache_path && cache_path[0] != '\0') {
        cef_request_context_settings_t context_settings;
        memset(&context_settings, 0, sizeof(context_settings));
        context_settings.size = sizeof(context_settings);
        set_cef_string(cache_path, &context_settings.cache_path);
        browser->request_context = cef_request_context_create_context_ptr(&context_settings, NULL);
        cef_string_utf16_clear_ptr(&context_settings.cache_path);
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

    cef_string_t url;
    memset(&url, 0, sizeof(url));
    set_cef_string(initial_url ? initial_url : "about:blank", &url);

    browser->browser = cef_browser_host_create_browser_sync_ptr(&window_info, &browser->client, &url, &browser_settings, NULL, browser->request_context);
    browser->view = window_info.view;
    cef_string_utf16_clear_ptr(&url);

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
    gsde_log(status);
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
    if (browser->browser && browser->browser->base.release) browser->browser->base.release((cef_base_ref_counted_t *)browser->browser);
    if (browser->request_context && browser->request_context->base.base.release) browser->request_context->base.base.release((cef_base_ref_counted_t *)browser->request_context);
    free(browser);
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

int gsde_chromium_browser_is_loading(gsde_chromium_browser_t *browser) {
    return browser ? browser->is_loading : 0;
}

int gsde_chromium_browser_http_status(gsde_chromium_browser_t *browser) {
    return browser ? browser->http_status : 0;
}

void gsde_chromium_browser_load_url(gsde_chromium_browser_t *browser, const char *url) {
#if GSDE_HAVE_CEF_HEADERS
    if (!browser || !browser->browser || !url) return;
    snprintf(browser->current_url, sizeof(browser->current_url), "%s", url);
    cef_frame_t *frame = browser->browser->get_main_frame(browser->browser);
    if (!frame) return;
    cef_string_t cef_url;
    memset(&cef_url, 0, sizeof(cef_url));
    set_cef_string(url, &cef_url);
    frame->load_url(frame, &cef_url);
    cef_string_utf16_clear_ptr(&cef_url);
    if (frame->base.release) frame->base.release((cef_base_ref_counted_t *)frame);
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
    host->show_dev_tools(host, &window_info, NULL, &settings, NULL);
#else
    (void)browser;
#endif
}
