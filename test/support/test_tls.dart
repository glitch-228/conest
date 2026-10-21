/// A self-signed certificate for site.example, for tests only (a local
/// https server; the client trusts it through its own SecurityContext).
library;

import 'dart:convert';
import 'dart:io';

const _certificate = '''
-----BEGIN CERTIFICATE-----
MIIBnzCCAUSgAwIBAgIUdrKaijt1y5+4uyHg5j+Jjaz5m9EwCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMc2l0ZS5leGFtcGxlMCAXDTI2MTAyMTA5NTkxN1oYDzIxMjYw
OTI3MDk1OTE3WjAXMRUwEwYDVQQDDAxzaXRlLmV4YW1wbGUwWTATBgcqhkjOPQIB
BggqhkjOPQMBBwNCAAQemv7Z9NlE/VMqWxUtMYtQ8ZWK/csS397Pvk3ZUmDbXs1Z
zFXWfBQhbh1Xwmy9zM+QVUzJY6RdJNIVnSlrbA7So2wwajAdBgNVHQ4EFgQUVIxZ
0CWgEQmJ6q7J6cS9UHFaB1IwHwYDVR0jBBgwFoAUVIxZ0CWgEQmJ6q7J6cS9UHFa
B1IwDwYDVR0TAQH/BAUwAwEB/zAXBgNVHREEEDAOggxzaXRlLmV4YW1wbGUwCgYI
KoZIzj0EAwIDSQAwRgIhANbQGuJaoGFbEol80NbhhLk2hre/05vNxqE7tIaQmHSA
AiEA/iZNsOx+3DW1/x+3KyNHFl6H8481VLZuZiMCPrFqVfE=
-----END CERTIFICATE-----
''';

const _key = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgJSlE3ANSqbW6WM20
+jtdnY3ho7/m1V1ycuiCCNq4/aehRANCAAQemv7Z9NlE/VMqWxUtMYtQ8ZWK/csS
397Pvk3ZUmDbXs1ZzFXWfBQhbh1Xwmy9zM+QVUzJY6RdJNIVnSlrbA7S
-----END PRIVATE KEY-----
''';

/// For a test server answering as site.example.
SecurityContext testServerContext() => SecurityContext()
  ..useCertificateChainBytes(utf8.encode(_certificate))
  ..usePrivateKeyBytes(utf8.encode(_key));

/// For a client that trusts only that server.
SecurityContext testClientContext() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(_certificate));
