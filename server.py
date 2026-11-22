"""바른분리 로컬 서버
- 이 폴더의 파일(recycle-finder-naver.html 등)을 http://localhost:8000 으로 제공
- /api/waste?sgg=청주시  →  공공데이터포털 '행정안전부 생활쓰레기배출정보' API를 대신 호출
- 인증키는 환경변수 DATA_GO_KR_KEY 또는 이 폴더의 .env 파일에서만 읽어요 (HTML에 넣지 마세요)

실행:  python server.py
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
UPSTREAM = "https://apis.data.go.kr/1741000/household_waste_info/info"
PORT = int(os.environ.get("PORT", "8000"))


def load_key():
    key = os.environ.get("DATA_GO_KR_KEY", "").strip()
    if key:
        return key
    env_path = os.path.join(HERE, ".env")
    if os.path.exists(env_path):
        with open(env_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("DATA_GO_KR_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=HERE, **kwargs)

    def send_json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/api/waste":
            return super().do_GET()

        qs = urllib.parse.parse_qs(parsed.query)
        sgg = (qs.get("sgg", [""])[0]).strip()
        if not sgg:
            return self.send_json(400, {"error": "sgg(시군구명) 파라미터가 필요해요. 예: /api/waste?sgg=청주시"})

        key = load_key()
        if not key:
            return self.send_json(500, {"error": "인증키가 없어요. 환경변수 DATA_GO_KR_KEY 또는 .env 파일에 키를 넣어 주세요."})

        # 키가 이미 인코딩(Encoding 키)된 형태면 그대로, 아니면 인코딩해서 사용
        enc_key = key if "%" in key else urllib.parse.quote(key, safe="")
        rest = urllib.parse.urlencode({
            "pageNo": "1",
            "numOfRows": "100",
            "cond[SGG_NM::LIKE]": sgg,
        })
        url = f"{UPSTREAM}?serviceKey={enc_key}&{rest}"
        try:
            with urllib.request.urlopen(url, timeout=15) as r:
                data = r.read()
                ctype = r.headers.get("Content-Type", "application/json; charset=utf-8")
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except urllib.error.HTTPError as e:
            self.send_json(e.code, {"error": "공공데이터 서버가 오류를 돌려줬어요", "status": e.code, "body": e.read().decode("utf-8", "replace")[:500]})
        except Exception as e:  # 네트워크 오류 등
            self.send_json(502, {"error": "공공데이터 서버에 연결하지 못했어요", "detail": str(e)})


if __name__ == "__main__":
    print(f"http://localhost:{PORT}/recycle-finder-naver.html 에서 열어 보세요 (종료: Ctrl+C)")
    if not load_key():
        print("※ DATA_GO_KR_KEY가 아직 없어요. /api/waste 는 키를 넣은 뒤에 동작해요.")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
