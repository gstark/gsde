#include "ChromiumStub.h"

int main(int argc, char **argv) {
    int exit_code = gsde_chromium_execute_process(argc, argv);
    return exit_code >= 0 ? exit_code : 0;
}
