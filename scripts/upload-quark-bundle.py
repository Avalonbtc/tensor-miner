#!/usr/bin/env python3
"""Resumable Quark Drive uploader for large lpminer bundle archives."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import mimetypes
import os
import subprocess
import sys
import time
import xml.sax.saxutils
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

try:
    import requests
except ImportError as exc:  # pragma: no cover - evaluated on the target host
    raise SystemExit(
        "缺少 requests；执行：python3 -m pip install --user requests"
    ) from exc


API = "https://drive.quark.cn/1/clouddrive"
REFERER = "https://pan.quark.cn/"
ORIGIN = "https://pan.quark.cn"
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"
)
HASH_CHUNK = 8 * 1024 * 1024


class UploadError(RuntimeError):
    pass


class LimitedReader:
    def __init__(self, handle, remaining: int) -> None:
        self.handle = handle
        self.remaining = remaining

    def read(self, size: int = -1) -> bytes:
        if self.remaining <= 0:
            return b""
        if size < 0 or size > self.remaining:
            size = self.remaining
        data = self.handle.read(size)
        self.remaining -= len(data)
        return data


class QuarkDrive:
    def __init__(self, cookie: str) -> None:
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Cookie": cookie,
                "Accept": "application/json, text/plain, */*",
                "Referer": REFERER,
                "Origin": ORIGIN,
                "User-Agent": USER_AGENT,
            }
        )

    def api(self, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        response = self.session.post(
            API + path,
            params={"pr": "ucpro", "fr": "pc"},
            json=payload or {},
            timeout=(30, 120),
        )
        response.raise_for_status()
        if response.cookies.get("__puus"):
            current = self.session.headers.get("Cookie", "")
            refreshed = f"__puus={response.cookies['__puus']}"
            if refreshed not in current:
                self.session.headers["Cookie"] = f"{current}; {refreshed}".strip("; ")
        body = response.json()
        if body.get("status", 200) >= 400 or body.get("code", 0) != 0:
            raise UploadError(str(body.get("message") or "Quark API request failed"))
        return body

    def pre_upload(self, name: str, size: int, parent_id: str, mime: str) -> dict[str, Any]:
        now = int(time.time() * 1000)
        return self.api(
            "/file/upload/pre",
            {
                "ccp_hash_update": True,
                "dir_name": "",
                "file_name": name,
                "format_type": mime,
                "l_created_at": now,
                "l_updated_at": now,
                "pdir_fid": parent_id,
                "size": size,
            },
        )

    def update_hash(self, md5: str, sha1: str, task_id: str) -> dict[str, Any]:
        return self.api(
            "/file/update/hash", {"md5": md5, "sha1": sha1, "task_id": task_id}
        )

    def authorize(self, pre: dict[str, Any], auth_meta: str) -> str:
        data = pre["data"]
        response = self.api(
            "/file/upload/auth",
            {
                "auth_info": data["auth_info"],
                "auth_meta": auth_meta,
                "task_id": data["task_id"],
            },
        )
        return str(response["data"]["auth_key"])

    def finish(self, pre: dict[str, Any]) -> None:
        data = pre["data"]
        self.api("/file/upload/finish", {"obj_key": data["obj_key"], "task_id": data["task_id"]})

    def create_folder(self, name: str, parent_id: str) -> str:
        response = self.api(
            "/file",
            {"pdir_fid": parent_id, "file_name": name, "dir_path": "", "dir_init_lock": False},
        )
        fid = str(response.get("data", {}).get("fid") or "")
        if not fid:
            raise UploadError(f"创建远程目录未返回 fid：{name}")
        return fid

    def create_share(self, fid: str, title: str) -> tuple[str, str]:
        response = self.api(
            "/share",
            {"fid_list": [fid], "title": title, "url_type": 1, "expired_type": 1},
        )
        task_id = str(response.get("data", {}).get("task_id") or "")
        if not task_id:
            raise UploadError("创建分享任务时未返回 task_id")
        for _ in range(60):
            response = self.session.get(
                API + "/task",
                params={"pr": "ucpro", "fr": "pc", "task_id": task_id, "retry_index": 0},
                timeout=(30, 120),
            )
            response.raise_for_status()
            body = response.json()
            if body.get("code", 0) != 0:
                raise UploadError(str(body.get("message") or "查询分享任务失败"))
            data = body.get("data", {})
            status = data.get("status")
            if status == 2:
                share_id = str(data.get("share_id") or "")
                info = self.api("/share/password", {"share_id": share_id}).get("data", {})
                return str(info.get("share_url") or ""), str(info.get("passcode") or info.get("pwd_id") or "")
            if status in (3, 4):
                raise UploadError(f"分享任务失败，状态={status}")
            time.sleep(5)
        raise UploadError("等待分享链接超时")


def utc_date() -> str:
    return datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")


def upload_url(pre: dict[str, Any]) -> str:
    data = pre["data"]
    suffix = str(data["upload_url"])
    if suffix.startswith("https://"):
        suffix = suffix[len("https://") :]
    return f"https://{data['bucket']}.{suffix.rstrip('/')}/{quote(str(data['obj_key']), safe='/')}"


def hash_file(path: Path) -> tuple[str, str]:
    md5 = hashlib.md5()
    sha1 = hashlib.sha1()
    with path.open("rb") as handle:
        while chunk := handle.read(HASH_CHUNK):
            md5.update(chunk)
            sha1.update(chunk)
    return md5.hexdigest(), sha1.hexdigest()


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return None


def save_json(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    os.chmod(path, 0o600)


def part_auth_meta(pre: dict[str, Any], mime: str, number: int, date: str) -> str:
    data = pre["data"]
    return (
        f"PUT\n\n{mime}\n{date}\n"
        f"x-oss-date:{date}\n"
        "x-oss-user-agent:aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit\n"
        f"/{data['bucket']}/{data['obj_key']}?partNumber={number}&uploadId={data['upload_id']}"
    )


def commit_auth_meta(pre: dict[str, Any], md5_b64: str, callback_b64: str, date: str) -> str:
    data = pre["data"]
    return (
        f"POST\n{md5_b64}\napplication/xml\n{date}\n"
        f"x-oss-callback:{callback_b64}\n"
        f"x-oss-date:{date}\n"
        "x-oss-user-agent:aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit\n"
        f"/{data['bucket']}/{data['obj_key']}?uploadId={data['upload_id']}"
    )


def put_part(
    client: QuarkDrive,
    pre: dict[str, Any],
    path: Path,
    mime: str,
    number: int,
    offset: int,
    length: int,
) -> str:
    date = utc_date()
    authorization = client.authorize(pre, part_auth_meta(pre, mime, number, date))
    headers = {
        "Authorization": authorization,
        "Content-Type": mime,
        "Content-Length": str(length),
        "Referer": REFERER,
        "x-oss-date": date,
        "x-oss-user-agent": "aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit",
    }
    params = {"partNumber": str(number), "uploadId": str(pre["data"]["upload_id"])}
    with path.open("rb") as handle:
        handle.seek(offset)
        response = client.session.put(
            upload_url(pre),
            headers=headers,
            params=params,
            data=LimitedReader(handle, length),
            timeout=(30, 900),
        )
    response.raise_for_status()
    etag = response.headers.get("ETag")
    if not etag:
        raise UploadError(f"第 {number} 分片未返回 ETag")
    return etag


def commit(client: QuarkDrive, pre: dict[str, Any], etags: dict[str, str]) -> None:
    parts = "".join(
        f"<Part><PartNumber>{number}</PartNumber><ETag>{xml.sax.saxutils.escape(etags[str(number)])}</ETag></Part>"
        for number in range(1, len(etags) + 1)
    )
    body = f'<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUpload>{parts}</CompleteMultipartUpload>'
    content_md5 = base64.b64encode(hashlib.md5(body.encode()).digest()).decode()
    callback_b64 = base64.b64encode(json.dumps(pre["data"]["callback"]).encode()).decode()
    date = utc_date()
    authorization = client.authorize(pre, commit_auth_meta(pre, content_md5, callback_b64, date))
    response = client.session.post(
        upload_url(pre),
        headers={
            "Authorization": authorization,
            "Content-MD5": content_md5,
            "Content-Type": "application/xml",
            "Referer": REFERER,
            "x-oss-callback": callback_b64,
            "x-oss-date": date,
            "x-oss-user-agent": "aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit",
        },
        params={"uploadId": str(pre["data"]["upload_id"])},
        data=body.encode(),
        timeout=(30, 900),
    )
    response.raise_for_status()


def upload_directory(
    client: QuarkDrive,
    cookie: str,
    directory: Path,
    parent_id: str,
    state_path: Path,
    share: bool,
    share_title: str | None,
) -> int:
    state = load_json(state_path) or {}
    if state.get("source") != str(directory) or state.get("parent_id") != parent_id:
        state = {"source": str(directory), "parent_id": parent_id, "dirs": {}, "completed": []}
    dirs = {str(key): str(value) for key, value in state.get("dirs", {}).items()}
    if "." not in dirs:
        dirs["."] = client.create_folder(directory.name, parent_id)
        state["dirs"] = dirs
        save_json(state_path, state)
    root_fid = dirs["."]
    completed = set(str(item) for item in state.get("completed", []))
    state_dir = state_path.with_name(state_path.name + ".parts")
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)

    for current, child_dirs, files in os.walk(directory):
        child_dirs.sort()
        files.sort()
        current_path = Path(current)
        relative_dir = str(current_path.relative_to(directory)) if current_path != directory else "."
        current_fid = dirs[relative_dir]
        for child in child_dirs:
            child_relative = child if relative_dir == "." else f"{relative_dir}/{child}"
            if child_relative not in dirs:
                dirs[child_relative] = client.create_folder(child, current_fid)
                state["dirs"] = dirs
                save_json(state_path, state)
        for name in files:
            file_path = current_path / name
            relative_file = name if relative_dir == "." else f"{relative_dir}/{name}"
            if relative_file in completed:
                continue
            token = hashlib.sha256(relative_file.encode("utf-8")).hexdigest()
            child_state = state_dir / f"{token}.json"
            command = [
                sys.executable,
                str(Path(__file__).resolve()),
                "--file",
                str(file_path),
                "--cookie-stdin",
                "--parent-id",
                current_fid,
                "--state-file",
                str(child_state),
            ]
            print(f"[quark-upload] uploading {relative_file}", flush=True)
            result = subprocess.run(command, input=cookie, text=True)
            if result.returncode != 0:
                raise UploadError(f"directory upload stopped at: {relative_file}")
            completed.add(relative_file)
            state["completed"] = sorted(completed)
            save_json(state_path, state)
    print(f"[quark-upload] directory upload complete: {directory.name}", flush=True)
    if share:
        url, passcode = client.create_share(root_fid, share_title or directory.name)
        print(f"[quark-upload] share URL: {url}", flush=True)
        if passcode:
            print(f"[quark-upload] share password: {passcode}", flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="可断点续传地上传 lpminer bundle 到夸克网盘")
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument(
        "--cookie-stdin",
        action="store_true",
        help="从标准输入读取一次夸克 Cookie，避免写入磁盘或命令行参数",
    )
    parser.add_argument("--parent-id", default="0")
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--share", action="store_true")
    parser.add_argument("--share-title")
    args = parser.parse_args()

    path = args.file.expanduser().resolve()
    if not args.cookie_stdin:
        raise UploadError("请使用 --cookie-stdin 并通过标准输入粘贴 Cookie")
    cookie = sys.stdin.read().strip()
    if not cookie:
        raise UploadError("Cookie 文件为空")
    if not args.parent_id:
        raise UploadError("parent-id 不能为空")
    if not path.exists():
        raise UploadError(f"文件或目录不存在：{path}")
    client = QuarkDrive(cookie)
    if path.is_dir():
        state_path = (args.state_file or path.with_name(path.name + ".quark-folder-state.json")).expanduser()
        return upload_directory(
            client,
            cookie,
            path,
            args.parent_id,
            state_path,
            args.share,
            args.share_title,
        )
    if not path.is_file():
        raise UploadError(f"不是常规文件：{path}")
    state_path = (args.state_file or path.with_name(path.name + ".quark-upload-state.json")).expanduser()
    size = path.stat().st_size
    print(f"[quark-upload] 计算文件哈希：{path.name} ({size / 1024**3:.2f} GiB)", flush=True)
    md5, sha1 = hash_file(path)
    state = load_json(state_path)
    valid_state = bool(
        state
        and state.get("file") == str(path)
        and state.get("size") == size
        and state.get("md5") == md5
        and state.get("sha1") == sha1
        and state.get("parent_id") == args.parent_id
        and isinstance(state.get("pre"), dict)
    )
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"

    if valid_state:
        pre = state["pre"]
        etags = {str(key): str(value) for key, value in state.get("etags", {}).items()}
        print(f"[quark-upload] 恢复任务，已完成 {len(etags)} 个分片", flush=True)
    else:
        pre = client.pre_upload(path.name, size, args.parent_id, mime)
        dedup = client.update_hash(md5, sha1, str(pre["data"]["task_id"]))
        if dedup.get("data", {}).get("finish"):
            print("[quark-upload] 网盘已有相同文件，秒传完成", flush=True)
            state_path.unlink(missing_ok=True)
            return 0
        etags = {}
        state = {
            "file": str(path),
            "size": size,
            "md5": md5,
            "sha1": sha1,
            "parent_id": args.parent_id,
            "pre": pre,
            "etags": etags,
        }
        save_json(state_path, state)

    part_size = int(pre["metadata"]["part_size"])
    total_parts = (size + part_size - 1) // part_size
    for number in range(1, total_parts + 1):
        if str(number) in etags:
            continue
        offset = (number - 1) * part_size
        length = min(part_size, size - offset)
        for attempt in range(1, 6):
            try:
                etags[str(number)] = put_part(client, pre, path, mime, number, offset, length)
                state["etags"] = etags
                save_json(state_path, state)
                done = min(size, offset + length)
                print(
                    f"[quark-upload] 分片 {number}/{total_parts}，{done / size:.1%}",
                    flush=True,
                )
                break
            except (requests.RequestException, UploadError) as exc:
                if attempt == 5:
                    raise UploadError(f"第 {number} 分片上传失败：{exc}") from exc
                delay = attempt * 5
                print(f"[quark-upload] 分片 {number} 失败，{delay}s 后重试：{exc}", file=sys.stderr, flush=True)
                time.sleep(delay)

    commit(client, pre, etags)
    client.finish(pre)
    state_path.unlink(missing_ok=True)
    fid = str(pre.get("data", {}).get("fid") or "")
    print(f"[quark-upload] 上传完成：{path.name}", flush=True)
    if args.share:
        if not fid:
            raise UploadError("上传完成但接口未返回 fid，无法创建分享")
        url, passcode = client.create_share(fid, args.share_title or path.name)
        print(f"[quark-upload] 分享链接：{url}", flush=True)
        if passcode:
            print(f"[quark-upload] 提取码：{passcode}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, ValueError, UploadError, requests.RequestException) as exc:
        print(f"[quark-upload] ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
