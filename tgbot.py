import asyncio
import os
import sys
from python_socks import ProxyType
from urllib.parse import urlparse
from telethon import TelegramClient
from telethon.tl.functions.help import GetConfigRequest

API_ID = 611335
API_HASH = "d524b414d21f4d37f08684c1df41ac9c"

BOT_TOKEN = os.environ.get("BOT_TOKEN")
CHAT_ID = os.environ.get("CHAT_ID")
PROXY_URL = (
    os.environ.get("ALL_PROXY")
    or os.environ.get("all_proxy")
    or os.environ.get("SOCKS_PROXY")
    or os.environ.get("socks_proxy")
    or os.environ.get("HTTPS_PROXY")
    or os.environ.get("https_proxy")
    or os.environ.get("HTTP_PROXY")
    or os.environ.get("http_proxy")
)
PROXY = None


def parse_proxy_url(url: str):
    url = urlparse(url)

    scheme = url.scheme.lower()
    if scheme in ('http', 'https'):
        ptype = ProxyType.HTTP
    elif scheme in ('socks5', 'socks'):
        ptype = ProxyType.SOCKS5
    elif scheme in ('socks4', 'socks4a'):
        ptype = ProxyType.SOCKS4
    else:
        raise ValueError(f"[-] Unsupported proxy scheme: {scheme}")

    host = url.hostname
    port = url.port
    username = url.username
    password = url.password

    if not host or not port:
        raise ValueError(f"[-] Invalid proxy URL: {url}")

    return (ptype, host, port, username, password)


def check_environ():
    print("[+] Checking environment")
    global CHAT_ID, BOT_TOKEN
    if BOT_TOKEN is None:
        print("[-] Invalid BOT_TOKEN")
        exit(1)
    if CHAT_ID is None:
        print("[-] Invalid CHAT_ID")
        exit(1)
    else:
        CHAT_ID = int(CHAT_ID)


def load_proxy():
    """
    读取环境变量 HTTP_PROXY / HTTPS_PROXY / SOCKS_PROXY / ALL_PROXY
    返回 Telethon 需要的代理格式:
        (ProxyType, host, port, username, password)
    无代理时返回 None
    """
    global PROXY
    if PROXY_URL:
        PROXY = parse_proxy_url(PROXY_URL)

    print(f"[+] Using proxy: {PROXY}")


async def main():
    check_environ()
    print("[+] Uploading to telegram")
    files = sys.argv[1:]
    if len(files) <= 0:
        print("[-] No files to upload")
        exit(1)
    print(f"[+] Files: {files}")
    load_proxy()
    print("[+] Logging in Telegram with bot")
    script_dir = os.path.dirname(os.path.abspath(sys.argv[0]))
    session_dir = os.path.join(script_dir, "tgbot.session")
    async with await TelegramClient(
        session=session_dir,
        api_id=API_ID,
        api_hash=API_HASH,
        use_ipv6=True,
        proxy=PROXY,
    ).start(bot_token=BOT_TOKEN) as bot:
        print("[+] Sending")
        await bot.send_file(entity=CHAT_ID, file=files, parse_mode=None, silent=False)
        print("[+] Done!")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        print(f"[-] An error occurred: {e}")
        exit(1)
