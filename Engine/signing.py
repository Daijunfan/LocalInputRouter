"""Stable local code identity; no certificate is added to system trust.

The private signing key stays in an encrypted, app-specific keychain. Its
unlock secret is stored in macOS Keychain, never in the repo or app bundle.
"""
from pathlib import Path
import json
import os
import secrets
import shlex
import subprocess
import tempfile

HOME_DIR = Path.home()
SIGNING = HOME_DIR / 'Library/Application Support/DJF Input Router/Signing'
SERVICE = 'com.djf.inputrouter.local-signing'
NAME = 'DJF Input Router Local Signing'

def run(arguments, env=None):
    result = subprocess.run(arguments, capture_output=True, env=env)
    if result.returncode:
        # Never render the argv: some Keychain operations contain generated secrets.
        raise RuntimeError('Local signing operation failed: ' + result.stderr.decode(errors='replace')[:500])
    return result.stdout

def sign(bundle, options=None, identifier='com.djf.inputrouter'):
    SIGNING.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = SIGNING / 'identity.json'
    keychain = SIGNING / 'signing.keychain-db'
    if info.exists():
        identity = json.loads(info.read_text())['sha1']
        password = run(['security', 'find-generic-password', '-s', SERVICE, '-a', os.getlogin(), '-w']).decode().strip()
    else:
        password = secrets.token_urlsafe(32)
        env = dict(os.environ, DJF_ROUTER_SIGNING_SECRET=password)
        with tempfile.TemporaryDirectory(prefix='djf-router-signing-') as temporary:
            folder = Path(temporary)
            config = folder / 'certificate.cnf'
            config.write_text(f'''[req]
prompt=no
distinguished_name=subject
x509_extensions=usage
[subject]
CN={NAME}
[usage]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
''')
            run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650',
                 '-config', str(config), '-keyout', str(folder/'key.pem'), '-out', str(folder/'cert.pem')])
            run(['openssl', 'pkcs12', '-export', '-name', NAME, '-inkey', str(folder/'key.pem'),
                 '-in', str(folder/'cert.pem'), '-out', str(folder/'identity.p12'), '-macalg', 'sha1',
                 '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-passout', 'env:DJF_ROUTER_SIGNING_SECRET'], env)
            search = shlex.split(run(['security', 'list-keychains', '-d', 'user']).decode())
            try:
                run(['security', 'create-keychain', '-p', password, str(keychain)])
            finally:
                run(['security', 'list-keychains', '-d', 'user', '-s', *search])
            run(['security', 'unlock-keychain', '-p', password, str(keychain)])
            run(['security', 'import', str(folder/'identity.p12'), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign'])
            run(['security', 'set-key-partition-list', '-S', 'apple-tool:,codesign:', '-s', '-k', password, str(keychain)])
            fingerprint = run(['openssl', 'x509', '-in', str(folder/'cert.pem'), '-noout', '-fingerprint', '-sha1']).decode()
            identity = fingerprint.split('=',1)[1].strip().replace(':','')
            run(['security', 'add-generic-password', '-U', '-s', SERVICE, '-a', os.getlogin(), '-w', password, '-T', '/usr/bin/security'])
            info.write_text(json.dumps({'sha1': identity, 'name': NAME}))
            info.chmod(0o600)
    run(['security', 'unlock-keychain', '-p', password, str(keychain)])
    search = shlex.split(run(['security', 'list-keychains', '-d', 'user']).decode())
    try:
        # codesign locates the matching private key through the search list even
        # with --keychain. Restore the user's list immediately after signing.
        run(['security', 'list-keychains', '-d', 'user', '-s', *search, str(keychain)])
        arguments = ['codesign', '--force', '--sign', identity, '--keychain', str(keychain), '--timestamp=none',
             '--identifier', identifier]
        if options is not None:
            arguments += ['--options', options]
        run(arguments + [str(bundle)])
    finally:
        run(['security', 'list-keychains', '-d', 'user', '-s', *search])
        run(['security', 'lock-keychain', str(keychain)])

if __name__ == '__main__':
    import sys
    sign(Path(sys.argv[1]))
    print('Signed with stable local app identity; system trust unchanged.')
