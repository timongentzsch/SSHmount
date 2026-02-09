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

static inline int ssh2_session_flag(LIBSSH2_SESSION *session, int flag, int value) {
    return libssh2_session_flag(session, flag, value);
}

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

// -- Method preference constants (macros not visible to Swift) --

static const int SSH2_METHOD_KEX       = 0;
static const int SSH2_METHOD_HOSTKEY   = 1;
static const int SSH2_METHOD_CRYPT_CS  = 2;
static const int SSH2_METHOD_CRYPT_SC  = 3;
static const int SSH2_METHOD_MAC_CS    = 4;
static const int SSH2_METHOD_MAC_SC    = 5;
static const int SSH2_METHOD_COMP_CS   = 6;
static const int SSH2_METHOD_COMP_SC   = 7;

static inline int ssh2_session_method_pref(LIBSSH2_SESSION *session,
                                            int method_type,
                                            const char *prefs) {
    return libssh2_session_method_pref(session, method_type, prefs);
}

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

// -- SFTP readdir --

static inline int ssh2_sftp_readdir(LIBSSH2_SFTP_HANDLE *handle,
                                     char *buffer,
                                     size_t buffer_maxlen,
                                     LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_readdir(handle, buffer, buffer_maxlen, attrs);
}

// -- SFTP stat --

static inline int ssh2_sftp_stat(LIBSSH2_SFTP *sftp,
                                  const char *path,
                                  LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_stat(sftp, path, attrs);
}

static inline int ssh2_sftp_lstat(LIBSSH2_SFTP *sftp,
                                   const char *path,
                                   LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_lstat(sftp, path, attrs);
}

static inline int ssh2_sftp_setstat(LIBSSH2_SFTP *sftp,
                                     const char *path,
                                     LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_setstat(sftp, path, attrs);
}

// -- SFTP file ops --

static inline LIBSSH2_SFTP_HANDLE *ssh2_sftp_open(LIBSSH2_SFTP *sftp,
                                                    const char *filename,
                                                    unsigned long flags,
                                                    long mode) {
    return libssh2_sftp_open(sftp, filename, flags, mode);
}

static inline int ssh2_sftp_mkdir(LIBSSH2_SFTP *sftp,
                                   const char *path,
                                   long mode) {
    return libssh2_sftp_mkdir(sftp, path, mode);
}

static inline int ssh2_sftp_rmdir(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_rmdir(sftp, path);
}

static inline int ssh2_sftp_unlink(LIBSSH2_SFTP *sftp,
                                    const char *filename) {
    return libssh2_sftp_unlink(sftp, filename);
}

static inline int ssh2_sftp_rename(LIBSSH2_SFTP *sftp,
                                    const char *sourcefile,
                                    const char *destfile) {
    return libssh2_sftp_rename(sftp, sourcefile, destfile);
}

static inline int ssh2_sftp_readlink(LIBSSH2_SFTP *sftp,
                                      const char *path,
                                      char *target,
                                      unsigned int maxlen) {
    return libssh2_sftp_readlink(sftp, path, target, maxlen);
}

#endif
