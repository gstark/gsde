#ifndef CHROMIUM_STUB_H
#define CHROMIUM_STUB_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct gsde_chromium_browser gsde_chromium_browser_t;

const char *gsde_chromium_backend_status(void);
const char *gsde_chromium_last_error(void);
int gsde_chromium_cef_available(void);
int gsde_chromium_execute_process(int argc, char **argv);
int gsde_chromium_initialize(const char *root_cache_path, const char *cache_path, const char *browser_subprocess_path);
void gsde_chromium_do_message_loop_work(void);
void gsde_chromium_shutdown(void);
int gsde_chromium_live_browser_count(void);

gsde_chromium_browser_t *gsde_chromium_browser_create(void *parent_nsview, int width, int height, const char *initial_url, const char *cache_path);
void *gsde_chromium_browser_view(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_destroy(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_resize(gsde_chromium_browser_t *browser, int width, int height);
const char *gsde_chromium_browser_current_url(gsde_chromium_browser_t *browser);
const char *gsde_chromium_browser_title(gsde_chromium_browser_t *browser);
const char *gsde_chromium_browser_status_message(gsde_chromium_browser_t *browser);
int gsde_chromium_browser_is_loading(gsde_chromium_browser_t *browser);
int gsde_chromium_browser_http_status(gsde_chromium_browser_t *browser);
double gsde_chromium_browser_loading_progress(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_load_url(gsde_chromium_browser_t *browser, const char *url);
int gsde_chromium_browser_can_go_back(gsde_chromium_browser_t *browser);
int gsde_chromium_browser_can_go_forward(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_go_back(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_go_forward(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_reload(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_reload_ignore_cache(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_stop(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_find(gsde_chromium_browser_t *browser, const char *query, int forward, int match_case, int find_next);
void gsde_chromium_browser_stop_finding(gsde_chromium_browser_t *browser, int clear_selection);
void gsde_chromium_browser_zoom_in(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_zoom_out(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_zoom_reset(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_print(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_cut(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_copy(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_paste(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_select_all(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_view_source(gsde_chromium_browser_t *browser);
void gsde_chromium_browser_focus(gsde_chromium_browser_t *browser, int focused);
void gsde_chromium_browser_show_devtools(gsde_chromium_browser_t *browser);

#ifdef __cplusplus
}
#endif

#endif
