#include "GhosttyShim.h"
#include "ghostty.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

struct ghostty_api {
    void *handle;
    int (*init)(uintptr_t, char **);
    ghostty_config_t (*config_new)(void);
    void (*config_free)(ghostty_config_t);
    void (*config_load_default_files)(ghostty_config_t);
    void (*config_finalize)(ghostty_config_t);
    ghostty_app_t (*app_new)(const ghostty_runtime_config_s *, ghostty_config_t);
    void (*app_free)(ghostty_app_t);
    void (*app_tick)(ghostty_app_t);
    void (*app_set_focus)(ghostty_app_t, bool);
    ghostty_surface_config_s (*surface_config_new)(void);
    ghostty_surface_t (*surface_new)(ghostty_app_t, const ghostty_surface_config_s *);
    void (*surface_free)(ghostty_surface_t);
    void (*surface_set_content_scale)(ghostty_surface_t, double, double);
    void (*surface_set_size)(ghostty_surface_t, uint32_t, uint32_t);
    void (*surface_set_focus)(ghostty_surface_t, bool);
    void (*surface_set_occlusion)(ghostty_surface_t, bool);
    void (*surface_draw)(ghostty_surface_t);
    void (*surface_text)(ghostty_surface_t, const char *, uintptr_t);
    void (*surface_preedit)(ghostty_surface_t, const char *, uintptr_t);
    void (*surface_ime_point)(ghostty_surface_t, double *, double *, double *, double *);
    void (*surface_complete_clipboard_request)(ghostty_surface_t, const char *, void *, bool);
    bool (*surface_key)(ghostty_surface_t, ghostty_input_key_s);
    bool (*surface_mouse_button)(ghostty_surface_t, ghostty_input_mouse_state_e, ghostty_input_mouse_button_e, ghostty_input_mods_e);
    void (*surface_mouse_pos)(ghostty_surface_t, double, double, ghostty_input_mods_e);
    void (*surface_mouse_scroll)(ghostty_surface_t, double, double, ghostty_input_scroll_mods_t);
    bool (*surface_has_selection)(ghostty_surface_t);
    bool (*surface_read_selection)(ghostty_surface_t, ghostty_text_s *);
    void (*surface_free_text)(ghostty_surface_t, ghostty_text_s *);
};

struct gsde_ghostty_host {
    ghostty_app_t app;
    ghostty_config_t config;
    ghostty_surface_t surface;
    char title[1024];
    ghostty_action_mouse_shape_e mouse_shape;
    ghostty_action_mouse_visibility_e mouse_visibility;
    struct gsde_ghostty_host *next;
};

static gsde_ghostty_host_t *hosts = NULL;

static struct ghostty_api api;
static char status[512] = "libghostty has not been loaded";
static bool attempted_load = false;

static gsde_ghostty_host_t *host_from_app(ghostty_app_t app) {
    for (gsde_ghostty_host_t *host = hosts; host; host = host->next) {
        if (host->app == app) return host;
    }
    return NULL;
}

static void register_host(gsde_ghostty_host_t *host) {
    host->next = hosts;
    hosts = host;
}

static void unregister_host(gsde_ghostty_host_t *host) {
    gsde_ghostty_host_t **cursor = &hosts;
    while (*cursor) {
        if (*cursor == host) {
            *cursor = host->next;
            host->next = NULL;
            return;
        }
        cursor = &(*cursor)->next;
    }
}

static char *read_command_output(const char *command, size_t max_bytes) {
    FILE *pipe = popen(command, "r");
    if (!pipe) return NULL;

    size_t capacity = 4096;
    char *buffer = malloc(capacity);
    if (!buffer) {
        pclose(pipe);
        return NULL;
    }

    size_t length = 0;
    while (!feof(pipe) && length < max_bytes) {
        if (length + 2048 > capacity) {
            capacity *= 2;
            if (capacity > max_bytes + 1) capacity = max_bytes + 1;
            char *grown = realloc(buffer, capacity);
            if (!grown) {
                free(buffer);
                pclose(pipe);
                return NULL;
            }
            buffer = grown;
        }
        size_t read_count = fread(buffer + length, 1, capacity - length - 1, pipe);
        length += read_count;
        if (read_count == 0) break;
    }
    int status_code = pclose(pipe);
    if (status_code == -1 || !WIFEXITED(status_code) || WEXITSTATUS(status_code) != 0 || length == 0) {
        free(buffer);
        return NULL;
    }
    buffer[length] = '\0';
    return buffer;
}

static bool write_command_input(const char *command, const char *data) {
    FILE *pipe = popen(command, "w");
    if (!pipe) return false;
    if (data && data[0] != '\0') fputs(data, pipe);
    int status_code = pclose(pipe);
    return status_code != -1 && WIFEXITED(status_code) && WEXITSTATUS(status_code) == 0;
}

static const char *text_plain_clipboard_content(const ghostty_clipboard_content_s *contents, size_t count) {
    if (!contents || count == 0) return NULL;
    for (size_t i = 0; i < count; i++) {
        const char *mime = contents[i].mime;
        if (mime && strcmp(mime, "text/plain") == 0) return contents[i].data;
    }
    return contents[0].data;
}

static void wakeup_cb(void *userdata) { (void)userdata; }
static bool action_cb(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    (void)target;
    gsde_ghostty_host_t *host = host_from_app(app);
    if (!host) return false;

    switch (action.tag) {
        case GHOSTTY_ACTION_SET_TITLE:
            snprintf(host->title, sizeof(host->title), "%s", action.action.set_title.title ? action.action.set_title.title : "");
            return true;
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            host->mouse_shape = action.action.mouse_shape;
            return true;
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            host->mouse_visibility = action.action.mouse_visibility;
            return true;
        default:
            return false;
    }
}
static bool read_clipboard_cb(void *userdata, ghostty_clipboard_e clipboard, void *request) {
    (void)clipboard;
    gsde_ghostty_host_t *host = userdata;
    if (!host || !host->surface || !request) return false;
    char *contents = read_command_output("/usr/bin/pbpaste", 1024 * 1024);
    if (!contents) return false;
    api.surface_complete_clipboard_request(host->surface, contents, request, false);
    free(contents);
    return true;
}

static void confirm_read_clipboard_cb(void *userdata, const char *title, void *request, ghostty_clipboard_request_e type) {
    (void)type;
    gsde_ghostty_host_t *host = userdata;
    if (!host || !host->surface || !request) return;
    api.surface_complete_clipboard_request(host->surface, title ? title : "", request, true);
}

static void write_clipboard_cb(void *userdata, ghostty_clipboard_e clipboard, const ghostty_clipboard_content_s *contents, size_t count, bool confirm) {
    (void)userdata; (void)clipboard; (void)confirm;
    const char *text = text_plain_clipboard_content(contents, count);
    if (!text) return;
    (void)write_command_input("/usr/bin/pbcopy", text);
}
static void close_surface_cb(void *userdata, bool confirm) { (void)userdata; (void)confirm; }

static void *load_symbol(const char *name) {
    void *symbol = dlsym(api.handle, name);
    if (!symbol) snprintf(status, sizeof(status), "libghostty is missing required symbol: %s", name);
    return symbol;
}

#define LOAD_SYM(field, symbol_name) do { api.field = load_symbol(symbol_name); if (!api.field) return false; } while (0)

static bool ensure_loaded(void) {
    if (api.handle) return true;
    if (attempted_load) return false;
    attempted_load = true;

    const char *env_path = getenv("LIBGHOSTTY_PATH");
    if (env_path && env_path[0] != '\0') {
        api.handle = dlopen(env_path, RTLD_NOW | RTLD_LOCAL);
    }

    const char *fallback_paths[] = {
        "@executable_path/../Frameworks/libghostty.dylib",
        "libghostty.dylib",
        "/opt/homebrew/lib/libghostty.dylib",
        "/usr/local/lib/libghostty.dylib",
        NULL,
    };

    for (int i = 0; !api.handle && fallback_paths[i] != NULL; i++) {
        api.handle = dlopen(fallback_paths[i], RTLD_NOW | RTLD_LOCAL);
    }

    if (!api.handle) {
        const char *err = dlerror();
        snprintf(status, sizeof(status), "libghostty.dylib not found. Set LIBGHOSTTY_PATH or place libghostty.dylib in GSDE.app/Contents/Frameworks. Last dlopen error: %s", err ? err : "unknown");
        return false;
    }

    LOAD_SYM(init, "ghostty_init");
    LOAD_SYM(config_new, "ghostty_config_new");
    LOAD_SYM(config_free, "ghostty_config_free");
    LOAD_SYM(config_load_default_files, "ghostty_config_load_default_files");
    LOAD_SYM(config_finalize, "ghostty_config_finalize");
    LOAD_SYM(app_new, "ghostty_app_new");
    LOAD_SYM(app_free, "ghostty_app_free");
    LOAD_SYM(app_tick, "ghostty_app_tick");
    LOAD_SYM(app_set_focus, "ghostty_app_set_focus");
    LOAD_SYM(surface_config_new, "ghostty_surface_config_new");
    LOAD_SYM(surface_new, "ghostty_surface_new");
    LOAD_SYM(surface_free, "ghostty_surface_free");
    LOAD_SYM(surface_set_content_scale, "ghostty_surface_set_content_scale");
    LOAD_SYM(surface_set_size, "ghostty_surface_set_size");
    LOAD_SYM(surface_set_focus, "ghostty_surface_set_focus");
    LOAD_SYM(surface_set_occlusion, "ghostty_surface_set_occlusion");
    LOAD_SYM(surface_draw, "ghostty_surface_draw");
    LOAD_SYM(surface_text, "ghostty_surface_text");
    LOAD_SYM(surface_preedit, "ghostty_surface_preedit");
    LOAD_SYM(surface_ime_point, "ghostty_surface_ime_point");
    LOAD_SYM(surface_complete_clipboard_request, "ghostty_surface_complete_clipboard_request");
    LOAD_SYM(surface_key, "ghostty_surface_key");
    LOAD_SYM(surface_mouse_button, "ghostty_surface_mouse_button");
    LOAD_SYM(surface_mouse_pos, "ghostty_surface_mouse_pos");
    LOAD_SYM(surface_mouse_scroll, "ghostty_surface_mouse_scroll");
    LOAD_SYM(surface_has_selection, "ghostty_surface_has_selection");
    LOAD_SYM(surface_read_selection, "ghostty_surface_read_selection");
    LOAD_SYM(surface_free_text, "ghostty_surface_free_text");

    char *argv[] = { (char *)"GSDE", NULL };
    int init_result = api.init(1, argv);
    if (init_result != GHOSTTY_SUCCESS) {
        snprintf(status, sizeof(status), "ghostty_init failed with code %d", init_result);
        return false;
    }

    snprintf(status, sizeof(status), "libghostty loaded");
    return true;
}

const char *gsde_ghostty_status(void) {
    ensure_loaded();
    return status;
}

const char *gsde_ghostty_host_title(gsde_ghostty_host_t *host) {
    return host ? host->title : "";
}

ghostty_action_mouse_shape_e gsde_ghostty_host_mouse_shape(gsde_ghostty_host_t *host) {
    return host ? host->mouse_shape : GHOSTTY_MOUSE_SHAPE_DEFAULT;
}

ghostty_action_mouse_visibility_e gsde_ghostty_host_mouse_visibility(gsde_ghostty_host_t *host) {
    return host ? host->mouse_visibility : GHOSTTY_MOUSE_VISIBLE;
}

gsde_ghostty_host_t *gsde_ghostty_host_create(void *nsview, double scale_factor, uint32_t width_px, uint32_t height_px) {
    if (!ensure_loaded()) return NULL;

    gsde_ghostty_host_t *host = calloc(1, sizeof(gsde_ghostty_host_t));
    if (!host) return NULL;

    snprintf(host->title, sizeof(host->title), "Terminal");
    host->mouse_shape = GHOSTTY_MOUSE_SHAPE_TEXT;
    host->mouse_visibility = GHOSTTY_MOUSE_VISIBLE;

    host->config = api.config_new();
    if (!host->config) {
        snprintf(status, sizeof(status), "ghostty_config_new failed");
        gsde_ghostty_host_destroy(host);
        return NULL;
    }

    api.config_load_default_files(host->config);
    api.config_finalize(host->config);

    ghostty_runtime_config_s runtime = {0};
    runtime.userdata = host;
    runtime.supports_selection_clipboard = false;
    runtime.wakeup_cb = wakeup_cb;
    runtime.action_cb = action_cb;
    runtime.read_clipboard_cb = read_clipboard_cb;
    runtime.confirm_read_clipboard_cb = confirm_read_clipboard_cb;
    runtime.write_clipboard_cb = write_clipboard_cb;
    runtime.close_surface_cb = close_surface_cb;

    host->app = api.app_new(&runtime, host->config);
    if (!host->app) {
        snprintf(status, sizeof(status), "ghostty_app_new failed");
        gsde_ghostty_host_destroy(host);
        return NULL;
    }

    ghostty_surface_config_s surface_config = api.surface_config_new();
    surface_config.platform_tag = GHOSTTY_PLATFORM_MACOS;
    surface_config.platform.macos.nsview = nsview;
    surface_config.userdata = host;
    surface_config.scale_factor = scale_factor;
    surface_config.font_size = 0;
    surface_config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;

    host->surface = api.surface_new(host->app, &surface_config);
    if (!host->surface) {
        snprintf(status, sizeof(status), "ghostty_surface_new failed");
        gsde_ghostty_host_destroy(host);
        return NULL;
    }

    register_host(host);
    gsde_ghostty_host_resize(host, scale_factor, width_px, height_px);
    gsde_ghostty_host_focus(host, true);
    snprintf(status, sizeof(status), "libghostty surface created");
    return host;
}

void gsde_ghostty_host_destroy(gsde_ghostty_host_t *host) {
    if (!host) return;
    unregister_host(host);
    if (api.surface_free && host->surface) api.surface_free(host->surface);
    if (api.app_free && host->app) api.app_free(host->app);
    if (api.config_free && host->config) api.config_free(host->config);
    free(host);
}

void gsde_ghostty_host_resize(gsde_ghostty_host_t *host, double scale_factor, uint32_t width_px, uint32_t height_px) {
    if (!host || !host->surface) return;
    api.surface_set_content_scale(host->surface, scale_factor, scale_factor);
    api.surface_set_size(host->surface, width_px, height_px);
    api.surface_draw(host->surface);
}

void gsde_ghostty_host_focus(gsde_ghostty_host_t *host, bool focused) {
    if (!host) return;
    if (host->app) api.app_set_focus(host->app, focused);
    if (host->surface) {
        api.surface_set_focus(host->surface, focused);
        api.surface_set_occlusion(host->surface, false);
    }
}

void gsde_ghostty_host_tick(gsde_ghostty_host_t *host) {
    if (host && host->app) api.app_tick(host->app);
}

void gsde_ghostty_host_draw(gsde_ghostty_host_t *host) {
    if (host && host->surface) api.surface_draw(host->surface);
}

void gsde_ghostty_host_text(gsde_ghostty_host_t *host, const char *text, uintptr_t len) {
    if (host && host->surface && text && len > 0) api.surface_text(host->surface, text, len);
}

void gsde_ghostty_host_preedit(gsde_ghostty_host_t *host, const char *text, uintptr_t len) {
    if (!host || !host->surface) return;
    api.surface_preedit(host->surface, text ? text : "", len);
}

void gsde_ghostty_host_ime_point(gsde_ghostty_host_t *host, double *x, double *y, double *width, double *height) {
    if (!host || !host->surface) return;
    api.surface_ime_point(host->surface, x, y, width, height);
}

bool gsde_ghostty_host_key(gsde_ghostty_host_t *host, ghostty_input_key_s event) {
    if (!host || !host->surface) return false;
    return api.surface_key(host->surface, event);
}

bool gsde_ghostty_host_mouse_button(gsde_ghostty_host_t *host, ghostty_input_mouse_state_e state, ghostty_input_mouse_button_e button, ghostty_input_mods_e mods) {
    if (!host || !host->surface) return false;
    return api.surface_mouse_button(host->surface, state, button, mods);
}

void gsde_ghostty_host_mouse_pos(gsde_ghostty_host_t *host, double x, double y, ghostty_input_mods_e mods) {
    if (!host || !host->surface) return;
    api.surface_mouse_pos(host->surface, x, y, mods);
}

void gsde_ghostty_host_mouse_scroll(gsde_ghostty_host_t *host, double x, double y, ghostty_input_scroll_mods_t mods) {
    if (!host || !host->surface) return;
    api.surface_mouse_scroll(host->surface, x, y, mods);
}

bool gsde_ghostty_host_has_selection(gsde_ghostty_host_t *host) {
    return host && host->surface && api.surface_has_selection(host->surface);
}

char *gsde_ghostty_host_read_selection(gsde_ghostty_host_t *host) {
    if (!host || !host->surface) return NULL;
    ghostty_text_s text = {0};
    if (!api.surface_read_selection(host->surface, &text) || !text.text || text.text_len == 0) return NULL;
    char *copy = malloc(text.text_len + 1);
    if (copy) {
        memcpy(copy, text.text, text.text_len);
        copy[text.text_len] = '\0';
    }
    api.surface_free_text(host->surface, &text);
    return copy;
}

void gsde_ghostty_free_string(char *text) {
    free(text);
}

bool gsde_ghostty_host_is_loaded(gsde_ghostty_host_t *host) {
    return host && host->surface;
}
