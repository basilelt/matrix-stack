#!/usr/bin/env python3
"""Cookie refresher — headless re-login for cookie-based Matrix bridges."""
import asyncio
import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

import pyotp
from cryptography.fernet import Fernet, InvalidToken
from playwright.async_api import async_playwright, BrowserContext, Page
from nio import AsyncClient, AsyncClientConfig, LoginResponse, RoomSendResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
log = logging.getLogger("cookie-refresher")


# ── Config & secrets ──────────────────────────────────────────────────────────

def load_config() -> Dict[str, Any]:
    path = Path("/app/config.json")
    with open(path) as f:
        return json.load(f)


def get_fernet() -> Fernet:
    key = os.environ.get("COOKIE_REFRESHER_KEY", "").strip()
    if not key:
        raise RuntimeError("COOKIE_REFRESHER_KEY env var not set")
    return Fernet(key.encode())


def load_secrets(cfg: Dict) -> Dict[str, Any]:
    path = Path(cfg["secrets_path"])
    if not path.exists():
        return {}
    fernet = get_fernet()
    try:
        data = fernet.decrypt(path.read_bytes())
        return json.loads(data)
    except InvalidToken:
        log.error("Failed to decrypt secrets — wrong COOKIE_REFRESHER_KEY?")
        return {}


def save_secrets(cfg: Dict, secrets: Dict) -> None:
    path = Path(cfg["secrets_path"])
    path.parent.mkdir(parents=True, exist_ok=True)
    fernet = get_fernet()
    encrypted = fernet.encrypt(json.dumps(secrets).encode())
    path.write_bytes(encrypted)


# ── Matrix client ─────────────────────────────────────────────────────────────

async def make_matrix_client(cfg: Dict) -> AsyncClient:
    client = AsyncClient(
        cfg["homeserver"],
        cfg["user_id"],
        config=AsyncClientConfig(max_limit_exceeded=0, max_timeouts=3),
    )
    resp = await client.login(cfg["password"], device_name=cfg.get("device_id", "COOKIEREFRESH01"))
    if not isinstance(resp, LoginResponse):
        raise RuntimeError(f"Matrix login failed: {resp}")
    log.info("Matrix login OK as %s", cfg["user_id"])
    return client


async def dm_bot(client: AsyncClient, bot_mxid: str, message: str) -> bool:
    """Create or find DM room with bot, send message. Returns True on success."""
    # Create DM room
    resp = await client.room_create(is_direct=True, invite=[bot_mxid])
    if hasattr(resp, "room_id"):
        room_id = resp.room_id
    else:
        log.error("Could not create DM room with %s: %s", bot_mxid, resp)
        return False

    await asyncio.sleep(2)  # let the bot join

    send_resp = await client.room_send(
        room_id,
        message_type="m.room.message",
        content={"msgtype": "m.text", "body": message},
    )
    if isinstance(send_resp, RoomSendResponse):
        log.info("Sent login command to %s in %s", bot_mxid, room_id)
        return True
    log.error("Failed to send message to %s: %s", bot_mxid, send_resp)
    return False


async def notify_admin(client: AsyncClient, admin_mxid: str, text: str) -> None:
    try:
        resp = await client.room_create(is_direct=True, invite=[admin_mxid])
        if hasattr(resp, "room_id"):
            await client.room_send(
                resp.room_id,
                "m.room.message",
                {"msgtype": "m.text", "body": f"[cookie-refresher] {text}"},
            )
    except Exception as e:
        log.warning("Could not notify admin: %s", e)


# ── Failure screenshot ────────────────────────────────────────────────────────

async def save_screenshot(page: Page, failures_dir: str, bridge: str) -> Optional[str]:
    try:
        d = Path(failures_dir)
        d.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        path = d / f"{bridge}-{ts}.png"
        await page.screenshot(path=str(path))
        return str(path)
    except Exception as e:
        log.warning("Screenshot failed: %s", e)
        return None


# ── Per-platform login flows ──────────────────────────────────────────────────

async def _fill_and_wait(page: Page, selector: str, value: str) -> None:
    await page.wait_for_selector(selector, timeout=15000)
    await page.fill(selector, value)


async def login_twitter(page: Page, creds: Dict) -> Optional[Dict[str, str]]:
    await page.goto("https://x.com/i/flow/login", wait_until="networkidle", timeout=30000)
    await _fill_and_wait(page, 'input[autocomplete="username"]', creds["username"])
    await page.keyboard.press("Enter")
    await asyncio.sleep(2)

    # Handle "enter phone/email" intermediate step X sometimes shows
    unusual = page.locator('input[data-testid="ocfEnterTextTextInput"]')
    if await unusual.count() > 0:
        await unusual.fill(creds.get("email", creds["username"]))
        await page.keyboard.press("Enter")
        await asyncio.sleep(2)

    await _fill_and_wait(page, 'input[name="password"]', creds["password"])
    await page.keyboard.press("Enter")
    await page.wait_for_url("https://x.com/home", timeout=20000)

    cookies = {c["name"]: c["value"] for c in await page.context.cookies()
               if c["name"] in ("auth_token", "ct0")}
    if "auth_token" not in cookies or "ct0" not in cookies:
        raise ValueError("auth_token or ct0 not found after Twitter login")
    return cookies


async def login_slack(page: Page, creds: Dict) -> Optional[Dict[str, str]]:
    workspace = creds.get("workspace_url", "https://slack.com/workspace-signin")
    await page.goto(workspace, wait_until="networkidle", timeout=30000)
    await _fill_and_wait(page, 'input[data-qa="login_email"]', creds["email"])
    await page.keyboard.press("Enter")
    await asyncio.sleep(1)
    await _fill_and_wait(page, 'input[data-qa="login_password"]', creds["password"])
    await page.keyboard.press("Enter")

    if creds.get("totp_secret"):
        code = pyotp.TOTP(creds["totp_secret"]).now()
        await _fill_and_wait(page, 'input[data-qa="mfa_code"]', code)
        await page.keyboard.press("Enter")

    await page.wait_for_url("**/client/**", timeout=20000)

    cookies = {c["name"]: c["value"] for c in await page.context.cookies()
               if c["name"] in ("d",)}
    local_xoxc = await page.evaluate(
        "JSON.parse(localStorage.getItem('localConfig_v2') || '{}').teams"
    )
    # Extract xoxc from localStorage (first team token)
    xoxc = None
    if isinstance(local_xoxc, dict):
        for team in local_xoxc.values():
            token = team.get("token", "")
            if token.startswith("xoxc-"):
                xoxc = token
                break
    xoxd = cookies.get("d", "")
    if not xoxc or not xoxd:
        raise ValueError("Could not extract xoxc/xoxd from Slack session")
    return {"xoxc": xoxc, "xoxd": xoxd}


async def login_meta(page: Page, creds: Dict, platform: str) -> Optional[Dict[str, str]]:
    if platform == "meta-fb":
        await page.goto("https://www.facebook.com/login", wait_until="networkidle", timeout=30000)
        await _fill_and_wait(page, '#email', creds["email"])
        await _fill_and_wait(page, '#pass', creds["password"])
        await page.click('button[name="login"]')
    else:
        await page.goto("https://www.instagram.com/accounts/login/", wait_until="networkidle", timeout=30000)
        await _fill_and_wait(page, 'input[name="username"]', creds["username"])
        await _fill_and_wait(page, 'input[name="password"]', creds["password"])
        await page.keyboard.press("Enter")

    if creds.get("totp_secret"):
        code = pyotp.TOTP(creds["totp_secret"]).now()
        try:
            await _fill_and_wait(page, 'input[name="approvals_code"]', code)
            await page.keyboard.press("Enter")
        except Exception:
            pass

    await asyncio.sleep(5)

    needed = {"meta-fb": ["c_user", "xs", "datr", "fr"],
              "meta-ig": ["sessionid", "csrftoken", "ds_user_id"]}[platform]
    cookies = {c["name"]: c["value"] for c in await page.context.cookies()
               if c["name"] in needed}
    missing = [k for k in needed if k not in cookies]
    if missing:
        raise ValueError(f"Missing cookies after {platform} login: {missing}")
    return cookies


async def login_linkedin(page: Page, creds: Dict) -> Optional[Dict[str, str]]:
    await page.goto("https://www.linkedin.com/login", wait_until="networkidle", timeout=30000)
    await _fill_and_wait(page, '#username', creds["email"])
    await _fill_and_wait(page, '#password', creds["password"])
    await page.click('button[type="submit"]')

    if creds.get("totp_secret"):
        code = pyotp.TOTP(creds["totp_secret"]).now()
        try:
            await _fill_and_wait(page, '#input__phone_verification_pin', code)
            await page.keyboard.press("Enter")
        except Exception:
            pass

    await page.wait_for_url("**/feed/**", timeout=20000)

    cookies = {c["name"]: c["value"] for c in await page.context.cookies()
               if c["name"] in ("li_at", "JSESSIONID")}
    if "li_at" not in cookies:
        raise ValueError("li_at not found after LinkedIn login")
    return cookies


async def do_login(browser_ctx: BrowserContext, bridge: str, creds: Dict) -> Optional[Dict]:
    page = await browser_ctx.new_page()
    await page.set_extra_http_headers({"Accept-Language": "en-US,en;q=0.9"})
    try:
        if bridge == "twitter":
            return await login_twitter(page, creds)
        elif bridge == "slack":
            return await login_slack(page, creds)
        elif bridge in ("meta-fb", "meta-ig"):
            return await login_meta(page, creds, bridge)
        elif bridge == "linkedin":
            return await login_linkedin(page, creds)
    finally:
        await page.close()
    return None


def build_login_command(bridge: str, bridge_cfg: Dict, cookies: Dict) -> str:
    template = bridge_cfg.get("login_command", "login-cookie")
    if bridge == "twitter":
        return f"login-cookie auth_token={cookies['auth_token']} ct0={cookies['ct0']}"
    elif bridge == "slack":
        return f"login-token {cookies['xoxc']} {cookies['xoxd']}"
    elif bridge in ("meta-fb", "meta-ig"):
        return "login-cookie " + json.dumps(cookies)
    elif bridge == "linkedin":
        jsessionid = cookies.get("JSESSIONID", "").strip('"')
        return f"login-cookie li_at={cookies['li_at']} JSESSIONID={jsessionid}"
    return template


# ── Main refresh loop ─────────────────────────────────────────────────────────

class Refresher:
    def __init__(self, cfg: Dict):
        self.cfg = cfg
        self.secrets: Dict = {}
        self.failure_counts: Dict[str, int] = {}
        self.disabled: set = set()
        self.last_run: Dict[str, float] = {}

    async def run(self):
        self.secrets = load_secrets(self.cfg)
        matrix = await make_matrix_client(self.cfg)

        async with async_playwright() as pw:
            browser = await pw.chromium.launch(headless=True, args=["--no-sandbox"])
            try:
                while True:
                    for bridge, bcfg in self.cfg["bridges"].items():
                        if not bcfg.get("enabled", False):
                            continue
                        if bridge in self.disabled:
                            continue
                        interval_s = bcfg.get("interval_hours", 24) * 3600
                        last = self.last_run.get(bridge, 0)
                        if time.time() - last < interval_s:
                            continue
                        await self._refresh_one(browser, matrix, bridge, bcfg)
                    await asyncio.sleep(60)
            finally:
                await browser.close()
                await matrix.close()

    async def _refresh_one(self, browser, matrix, bridge: str, bcfg: Dict):
        creds = self.secrets.get(bridge)
        if not creds:
            log.warning("No credentials seeded for %s — skipping", bridge)
            return

        log.info("Refreshing cookies for %s", bridge)
        ctx = await browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            )
        )
        try:
            cookies = await do_login(ctx, bridge, creds)
            if cookies is None:
                raise ValueError("Login returned no cookies")

            cmd = build_login_command(bridge, bcfg, cookies)
            ok = await dm_bot(matrix, bcfg["bot_mxid"], cmd)
            if ok:
                log.info("%s: login command sent successfully", bridge)
                self.last_run[bridge] = time.time()
                self.failure_counts[bridge] = 0
            else:
                raise RuntimeError("DM to bridge bot failed")

        except Exception as e:
            count = self.failure_counts.get(bridge, 0) + 1
            self.failure_counts[bridge] = count
            log.error("%s: refresh failed (attempt %d): %s", bridge, count, e)

            # Save failure screenshot
            page = await ctx.new_page()
            screenshot = await save_screenshot(page, self.cfg.get("failures_dir", "/app/data/failures"), bridge)
            await page.close()

            msg = f"Cookie refresh FAILED for {bridge} (attempt {count}): {e}"
            if screenshot:
                msg += f"\nScreenshot: {screenshot}"
            await notify_admin(matrix, self.cfg.get("admin_notify_user", ""), msg)

            if count >= 3:
                log.error("%s: 3 consecutive failures — disabling auto-refresh to prevent ban", bridge)
                self.disabled.add(bridge)
                await notify_admin(
                    matrix,
                    self.cfg.get("admin_notify_user", ""),
                    f"Auto-refresh DISABLED for {bridge} after 3 failures. Manual login required.",
                )
        finally:
            await ctx.close()


async def main():
    cfg = load_config()
    refresher = Refresher(cfg)
    await refresher.run()


if __name__ == "__main__":
    asyncio.run(main())
