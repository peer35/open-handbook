#!/usr/bin/env python3
import io, os, re, shutil, tarfile
from http.server import HTTPServer, BaseHTTPRequestHandler

SECRET      = os.environ['DEPLOY_SECRET']
PREVIEW_DIR = os.environ.get('PREVIEW_DIR', '/previews')

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # container stdout/stderr handled by Docker logging

    def _auth(self):
        return self.headers.get('Authorization') == f'Bearer {SECRET}'

    def _pr(self):
        m = re.fullmatch(r'/pr-(\d{1,6})', self.path)
        return m.group(1) if m else None

    def _respond(self, code, body=b''):
        self.send_response(code)
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self._auth():
            return self._respond(403, b'Forbidden')
        pr = self._pr()
        if not pr:
            return self._respond(400, b'Bad path')

        length = int(self.headers.get('Content-Length', 0))
        data = self.rfile.read(length)
        dest = os.path.join(PREVIEW_DIR, f'pr-{pr}')
        tmp  = dest + '.tmp'

        try:
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
                for m in tar.getmembers():
                    if os.path.isabs(m.name) or '..' in m.name.split('/'):
                        return self._respond(400, b'Bad archive')
                if os.path.exists(tmp):
                    shutil.rmtree(tmp)
                tar.extractall(tmp)
            if os.path.exists(dest):
                shutil.rmtree(dest)
            os.rename(tmp, dest)
        except Exception as e:
            return self._respond(500, str(e).encode())

        self._respond(200, b'OK')

    def do_DELETE(self):
        if not self._auth():
            return self._respond(403, b'Forbidden')
        pr = self._pr()
        if not pr:
            return self._respond(400, b'Bad path')
        dest = os.path.join(PREVIEW_DIR, f'pr-{pr}')
        if os.path.exists(dest):
            shutil.rmtree(dest)
        self._respond(200, b'OK')

if __name__ == '__main__':
    print(f'Listening on 0.0.0.0:9000, serving previews from {PREVIEW_DIR}', flush=True)
    HTTPServer(('0.0.0.0', 9000), Handler).serve_forever()
