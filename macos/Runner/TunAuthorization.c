#include "TunAuthorization.h"

#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

FlClashTunAuthorization FlClashAuthorizeCore(const char *path) {
    AuthorizationItem item = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(&rights, NULL,
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights, &authorization);
    if (status != errAuthorizationSuccess) {
        return FlClashTunAuthorizationFailed;
    }

    char command[] = "--authorize-macos-tun";
    char *arguments[] = { command, NULL };
    FILE *pipe = NULL;
    // Apple documents this legacy API for one-shot setuid repair.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = AuthorizationExecuteWithPrivileges(authorization, path, kAuthorizationFlagDefaults, arguments, &pipe);
#pragma clang diagnostic pop
    AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
    if (status != errAuthorizationSuccess || pipe == NULL) {
        os_log_error(OS_LOG_DEFAULT, "FlClashCore TUN authorization execution failed: %d", status);
        return FlClashTunPermissionFailed;
    }

    char response[128] = { 0 };
    bool ready = fgets(response, sizeof(response), pipe) != NULL && strcmp(response, "ready\n") == 0;
    fclose(pipe);
    if (!ready) {
        os_log_error(OS_LOG_DEFAULT, "FlClashCore TUN permission setup failed: %{private}s", response);
    }
    return ready ? FlClashTunReady : FlClashTunPermissionFailed;
}
