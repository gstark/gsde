#include "ChromiumStub.h"

#include <dlfcn.h>
#include <stddef.h>

const char *gsde_chromium_backend_status(void) {
#if GSDE_ENABLE_CEF
    return "CEF backend compiled in";
#else
    return "WebKit fallback backend active; CEF bridge is not compiled into this build";
#endif
}

int gsde_chromium_cef_available(void) {
#if GSDE_ENABLE_CEF
    void *handle = dlopen("@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework", RTLD_NOW | RTLD_LOCAL);
    if (handle) {
        dlclose(handle);
        return 1;
    }
    return 0;
#else
    return 0;
#endif
}
