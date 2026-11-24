typedef enum {
    FlClashTunReady,
    FlClashTunAuthorizationFailed,
    FlClashTunPermissionFailed,
} FlClashTunAuthorization;

FlClashTunAuthorization FlClashAuthorizeCore(const char *path);
