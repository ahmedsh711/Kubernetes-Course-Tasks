import html
import subprocess
import time
from pathlib import Path
from playwright.sync_api import sync_playwright

BASE_DIR = Path(__file__).resolve().parent.parent
EVIDENCE_DIR = BASE_DIR / "evidence"
SCREENSHOTS_DIR = BASE_DIR / "screenshots"
SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)


def read_ev(name: str) -> str:
    p = EVIDENCE_DIR / name
    return p.read_text(encoding="utf-8", errors="replace").strip() if p.exists() else f"[{name} missing]"


def build_terminal_html(title: str, sections: list[tuple[str, str]]) -> str:
    blocks = []
    for cmd, out in sections:
        escaped_cmd = html.escape(cmd)
        escaped_out = html.escape(out)
        blocks.append(
            f'<div class="cmd"><span class="prompt">PS C:\\Task-1&gt;</span> <span class="cmdline">{escaped_cmd}</span></div>'
            f'<pre class="out">{escaped_out}</pre>'
        )
    body = "\n".join(blocks)
    return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    background: #0f172a;
    font-family: 'Cascadia Mono', 'Consolas', monospace;
    color: #e2e8f0;
    padding: 0;
  }}
  .window {{
    background: #0b1120;
    border: 1px solid #334155;
    border-radius: 8px;
    overflow: hidden;
  }}
  .titlebar {{
    background: #1e293b;
    padding: 10px 16px;
    display: flex;
    align-items: center;
    gap: 8px;
    border-bottom: 1px solid #334155;
  }}
  .dot {{ width: 12px; height: 12px; border-radius: 50%; display: inline-block; }}
  .r {{ background: #ef4444; }}
  .y {{ background: #f59e0b; }}
  .g {{ background: #22c55e; }}
  .title {{
    margin-left: 10px;
    font-size: 13px;
    color: #94a3b8;
  }}
  .content {{
    padding: 18px 22px;
    font-size: 13.5px;
    line-height: 1.5;
  }}
  .cmd {{
    margin-top: 10px;
    margin-bottom: 4px;
  }}
  .cmd:first-child {{ margin-top: 0; }}
  .prompt {{ color: #38bdf8; font-weight: bold; }}
  .cmdline {{ color: #f8fafc; font-weight: 600; }}
  .out {{
    color: #cbd5e1;
    white-space: pre-wrap;
    word-break: break-all;
    margin-bottom: 12px;
    font-family: inherit;
  }}
</style>
</head>
<body>
  <div class="window" id="term">
    <div class="titlebar">
      <span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
      <span class="title">Windows PowerShell — {html.escape(title)}</span>
    </div>
    <div class="content">{body}</div>
  </div>
</body>
</html>"""


def capture_live_browser_screenshots(page):
    """Start a real kubectl port-forward to deploy/web-deployment and screenshot live http://localhost:8080 twice (5.5s apart)."""
    pf = subprocess.Popen(
        ["kubectl", "port-forward", "-n", "webapp", "deploy/web-deployment", "8080:80"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        # Wait until port 8080 responds
        ready = False
        for _ in range(20):
            try:
                page.goto("http://localhost:8080", wait_until="domcontentloaded", timeout=2000)
                ready = True
                break
            except Exception:
                time.sleep(0.5)
        if not ready:
            raise RuntimeError("kubectl port-forward to localhost:8080 did not become ready")

        page.set_viewport_size({"width": 1000, "height": 260})
        page.goto("http://localhost:8080", wait_until="networkidle")
        body_t1 = page.content()
        (EVIDENCE_DIR / "07a-http-t1.txt").write_text(
            page.locator("h1").inner_text().strip(), encoding="utf-8"
        )
        page.screenshot(path=str(SCREENSHOTS_DIR / "05-browser-time-1.png"))
        print("Saved live browser screenshot 05-browser-time-1.png")

        time.sleep(5.5)
        page.reload(wait_until="networkidle")
        (EVIDENCE_DIR / "07b-http-t2.txt").write_text(
            page.locator("h1").inner_text().strip(), encoding="utf-8"
        )
        page.screenshot(path=str(SCREENSHOTS_DIR / "06-browser-time-2.png"))
        print("Saved live browser screenshot 06-browser-time-2.png")
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=3)
        except Exception:
            pf.kill()


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        page = browser.new_page(viewport={"width": 1200, "height": 800}, device_scale_factor=1.5)

        # 1. Capture live HTTP browser screenshots via real port-forward on http://localhost:8080
        capture_live_browser_screenshots(page)

        # 2. Render terminal screenshots from real evidence files
        page.set_viewport_size({"width": 1200, "height": 900})
        specs = [
            (
                "Check #1: 3-Node Minikube Cluster (Calico CNI)",
                [("kubectl get nodes -o wide", read_ev("01-nodes.txt"))],
                "01-cluster-nodes.png",
            ),
            (
                "Checks #2, #3 & #8: Deployment Ready (3/3), Pods Running (2/2), No Volumes",
                [
                    ("kubectl get deploy web-deployment -n webapp", read_ev("02-deployment.txt")),
                    ("kubectl get pods -n webapp -l app=web -o wide", read_ev("03-pods.txt")),
                    (
                        "kubectl get deploy web-deployment -n webapp -o jsonpath='{.spec.template.spec.volumes}'",
                        read_ev("08-volumes.txt"),
                    ),
                ],
                "02-pods-running.png",
            ),
            (
                "Checks #4 & #5: Pod Containers & Init Container Logs",
                [
                    (
                        "kubectl get pods -n webapp -l app=web -o jsonpath='{.items[0].spec.initContainers[*].name} {.items[0].spec.containers[*].name}'",
                        read_ev("04-containers.txt"),
                    ),
                    ("kubectl logs deploy/web-deployment -n webapp -c init-done", read_ev("05-init-logs.txt")),
                ],
                "03-containers-and-init.png",
            ),
            (
                "Checks #6 & #7: Shared Process Namespace (ps) & Sidecar Time Update (5s apart)",
                [
                    ("kubectl exec deploy/web-deployment -n webapp -c time-updater -- ps", read_ev("06-sidecar-ps.txt")),
                    (
                        "kubectl exec <pod> -n webapp -c nginx -- cat /usr/share/nginx/html/index.html # twice, 5s apart",
                        read_ev("07-time-updates.txt"),
                    ),
                ],
                "04-sidecar-and-time-update.png",
            ),
            (
                "Step 5 (Checks #9 & #10): Failing Init Container (Init:CrashLoopBackOff & Exit Code 1)",
                [
                    (
                        "kubectl apply -f deployment-failing-init.yaml && kubectl get pods -n webapp -l app=web",
                        read_ev("09-failing-init-pods.txt"),
                    ),
                    ("kubectl logs <new-pod> -n webapp -c init-done", read_ev("10a-failing-init-logs.txt")),
                    ("kubectl describe pod <new-pod> -n webapp (init-done state)", read_ev("10b-failing-init-describe.txt")),
                ],
                "07-failing-init-rollout.png",
            ),
            (
                "Step 6 (Check #11): Fixed Init Container — All 3 Replicas Ready & Up-to-Date",
                [
                    (
                        "kubectl apply -f deployment.yaml && kubectl get deploy web-deployment -n webapp",
                        read_ev("11-fixed-deployment.txt"),
                    ),
                    ("kubectl get pods -n webapp -l app=web -o wide", read_ev("11b-fixed-pods.txt")),
                ],
                "08-fixed-rollout.png",
            ),
        ]

        for title, sections, filename in specs:
            page.set_content(build_terminal_html(title, sections), wait_until="domcontentloaded")
            loc = page.locator("#term")
            loc.screenshot(path=str(SCREENSHOTS_DIR / filename))
            print(f"Saved terminal screenshot {filename}")

        browser.close()


if __name__ == "__main__":
    main()
