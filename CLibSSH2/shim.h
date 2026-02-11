#ifndef CLIBSSH2_SHIM_H
#define CLIBSSH2_SHIM_H

#include <libssh2.h>
#include <libssh2_sftp.h>
#include <notify.h>
#include <string.h>

// Swift can't see C preprocessor macros. These inline functions
// expose the macro-based convenience APIs to Swift.

// -- Session --

static inline LIBSSH2_SESSION *ssh2_session_init(void) {
    return libssh2_session_init();
}

static inline int ssh2_session_disconnect(LIBSSH2_SESSION *session,
                                           const char *description) {
    return libssh2_session_disconnect(session, description);
}

static inline int ssh2_session_last_errno(LIBSSH2_SESSION *session) {
    return libssh2_session_last_errno(session);
}

static inline int ssh2_session_block_directions(LIBSSH2_SESSION *session) {
    return libssh2_session_block_directions(session);
}

// -- Session options --

static inline void ssh2_session_set_timeout(LIBSSH2_SESSION *session, long timeout) {
    libssh2_session_set_timeout(session, timeout);
}

static inline void ssh2_keepalive_config(LIBSSH2_SESSION *session,
                                          int want_reply,
                                          unsigned interval) {
    libssh2_keepalive_config(session, want_reply, interval);
}

static inline int ssh2_keepalive_send(LIBSSH2_SESSION *session,
                                      int *seconds_to_next) {
    return libssh2_keepalive_send(session, seconds_to_next);
}

// -- Common libssh2 constants --

static const int SSH2_ERROR_EAGAIN = LIBSSH2_ERROR_EAGAIN;
static const int SSH2_SESSION_BLOCK_INBOUND = LIBSSH2_SESSION_BLOCK_INBOUND;
static const int SSH2_SESSION_BLOCK_OUTBOUND = LIBSSH2_SESSION_BLOCK_OUTBOUND;

// -- Auth --

static inline int ssh2_userauth_publickey_fromfile(LIBSSH2_SESSION *session,
                                                    const char *username,
                                                    const char *publickey,
                                                    const char *privatekey,
                                                    const char *passphrase) {
    return libssh2_userauth_publickey_fromfile(session, username,
                                                publickey, privatekey,
                                                passphrase);
}

static inline int ssh2_userauth_password(LIBSSH2_SESSION *session,
                                         const char *username,
                                         const char *password) {
    if (username == NULL || password == NULL) {
        return -1;
    }
    return libssh2_userauth_password_ex(
        session,
        username, (unsigned int)strlen(username),
        password, (unsigned int)strlen(password),
        NULL
    );
}

// -- SFTP open/close --

static inline LIBSSH2_SFTP_HANDLE *ssh2_sftp_opendir(LIBSSH2_SFTP *sftp,
                                                       const char *path) {
    return libssh2_sftp_opendir(sftp, path);
}

static inline int ssh2_sftp_close(LIBSSH2_SFTP_HANDLE *handle) {
    return libssh2_sftp_close(handle);
}

static inline int ssh2_sftp_closedir(LIBSSH2_SFTP_HANDLE *handle) {
    return libssh2_sftp_closedir(handle);
}

// -- SFTP helpers --

static inline int ssh2_sftp_fsync(LIBSSH2_SFTP_HANDLE *handle) {
    return libssh2_sftp_fsync(handle);
}

static inline int ssh2_sftp_posix_rename_ex(LIBSSH2_SFTP *sftp,
                                            const char *oldpath,
                                            unsigned int oldpath_len,
                                            const char *newpath,
                                            unsigned int newpath_len) {
    return libssh2_sftp_posix_rename_ex(sftp, oldpath, oldpath_len, newpath, newpath_len);
}

#endif
