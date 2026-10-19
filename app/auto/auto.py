import os, random, time, json, urllib.request

CORE = os.environ.get("CORE_URL", "http://core:5000")
INTERVAL = int(os.environ.get("INTERVAL", "60"))
PAGES = ["home", "courses", "contact", "about"]

def call(path, data=None):
    req = urllib.request.Request(
        CORE + path,
        data=json.dumps(data).encode() if data else None,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status

while True:
    try:
        call("/health")
        page, rating = random.choice(PAGES), random.randint(1, 5)
        status = call("/items", {"name": f"rating page={page} stars={rating}"})
        print(f"fed rating {page}/{rating} -> HTTP {status}", flush=True)
    except Exception as e:
        print(f"core not ready: {e}", flush=True)
    time.sleep(INTERVAL)
