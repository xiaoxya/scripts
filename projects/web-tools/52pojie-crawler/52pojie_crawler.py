#!/usr/bin/env python3
"""
52pojie 破解者论坛 - 软件发布区定时爬虫
使用 DrissionPage 绕过 WAF 保护，定时抓取最新发布内容
"""

import json
import os
import time
import logging
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Optional

try:
    from DrissionPage import ChromiumPage
except ImportError:
    print("请先安装: pip install DrissionPage")
    raise

# ─── 配置 ────────────────────────────────────────────
CONFIG = {
    "url": "https://www.52pojie.cn/forum-16-1.html",
    "save_dir": str(Path.home() / "52pojie_data"),
    "interval_minutes": 30,       # 抓取间隔（分钟）
    "run_once": True,             # True=只跑一次退出；False=持续运行
    "max_pages": 1,               # 抓取前几页（每页20条）
    "headless": False,            # True=无头模式（后台运行）
    "log_file": None,             # 日志文件路径，None=只输出到终端
}

# ─── 日志 ────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("52pojie")
if CONFIG["log_file"]:
    fh = logging.FileHandler(CONFIG["log_file"], encoding="utf-8")
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S"))
    logger.addHandler(fh)


# ─── 数据模型 ──────────────────────────────────────────
@dataclass
class Post:
    title: str
    url: str
    author: str
    replies: str
    views: str
    publish_time: str
    last_reply_time: str = ""
    source: str = "52pojie"

    def to_dict(self):
        return asdict(self)


# ─── 解析器 ────────────────────────────────────────────
def parse_posts(page: ChromiumPage, page_num: int = 1) -> list[Post]:
    """解析当前页面的帖子列表，返回 Post 对象列表"""
    posts = []

    # 52pojie 的帖子列表在 <table id="postlist"> 中
    post_tables = page.eles("tag:table")
    for table in post_tables:
        classes = table.get("class", "")
        if "postlist" in classes:
            rows = table.eles("tag:tr")
            for row in rows:
                row_class = row.get("class", "")
                if "authi" not in row_class and "container" not in row_class:
                    try:
                        # 标题链接
                        title_link = row.ele("tag:a@class=title")
                        if not title_link:
                            title_link = row.ele("tag:a.new")
                        if not title_link:
                            continue

                        title = title_link.text.strip()
                        url = title_link.attr("href", check=False)
                        if url and not url.startswith("http"):
                            url = f"https://www.52pojie.cn/{url.lstrip('/')}"

                        # 作者
                        author_el = row.ele("tag:em", timeout=1)
                        author = author_el.text.strip() if author_el else ""

                        # 回复数 & 查看数
                        replies = ""
                        views = ""
                        for td in row.eles("tag:td"):
                            td_class = td.get("class", "")
                            if "by" in td_class:
                                # 作者列的后面可能跟着回复数
                                pass
                            if "num" in td_class:
                                num_text = td.text.strip()
                                if "回复" in num_text:
                                    replies = num_text
                                elif "查看" in num_text:
                                    views = num_text

                        # 时间信息
                        time_text = row.ele("tag:span@class=authi").text.strip() if row.ele("tag:span@class=authi") else ""
                        publish_time = ""
                        last_reply = ""
                        if time_text:
                            parts = time_text.split("|")
                            if len(parts) >= 2:
                                publish_time = parts[0].strip()
                                last_reply = parts[1].strip()

                        if title:
                            posts.append(Post(
                                title=title,
                                url=url,
                                author=author,
                                replies=replies,
                                views=views,
                                publish_time=publish_time,
                                last_reply_time=last_reply,
                            ))
                    except Exception as e:
                        logger.debug(f"解析行失败: {e}")
            break  # 只解析第一个 postlist table

    # 如果上面的方式没拿到，尝试备用方案
    if not posts:
        posts = parse_posts_fallback(page)

    return posts


def parse_posts_fallback(page: ChromiumPage) -> list[Post]:
    """备用解析方案：遍历所有链接"""
    posts = []
    # 查找所有帖子标题链接
    links = page.eles("tag:a.new, tag:a[href*='thread-']")
    for link in links:
        title = link.text.strip()
        href = link.attr("href")
        if not title or not href:
            continue
        # 提取作者和时间
        row = link.ele("@tag:tr", timeout=1)
        author = ""
        pub_time = ""
        if row:
            author_el = row.ele("tag:em", timeout=0.5)
            author = author_el.text.strip() if author_el else ""
            time_el = row.ele("tag:span", timeout=0.5)
            if time_el:
                pub_time = time_el.text.strip()

        url = f"https://www.52pojie.cn/{href.lstrip('/')}" if not href.startswith("http") else href
        posts.append(Post(title=title, url=url, author=author, replies="", views="", publish_time=pub_time))

    return posts


# ─── 数据持久化 ────────────────────────────────────────
def load_existing_data(save_dir: str) -> dict:
    """加载已有数据文件"""
    data_file = os.path.join(save_dir, "posts.json")
    if os.path.exists(data_file):
        with open(data_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {"posts": [], "last_update": None}


def save_data(save_dir: str, new_posts: list[Post], last_update: str):
    """保存数据，去重"""
    os.makedirs(save_dir, exist_ok=True)
    data = load_existing_data(save_dir)

    # 用 URL 去重
    existing_urls = {p["url"] for p in data["posts"]}
    for post in new_posts:
        if post.url not in existing_urls:
            data["posts"].insert(0, post.to_dict())  # 新的放前面

    data["last_update"] = last_update
    # 只保留最近 500 条
    data["posts"] = data["posts"][:500]

    data_file = os.path.join(save_dir, "posts.json")
    with open(data_file, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    logger.info(f"已保存 {len(new_posts)} 条新数据（累计 {len(data['posts'])} 条）→ {data_file}")


def save_latest_summary(save_dir: str, posts: list[Post]):
    """保存最新帖子摘要到文本文件，方便快速查看"""
    os.makedirs(save_dir, exist_ok=True)
    summary_file = os.path.join(save_dir, "latest_summary.txt")
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    with open(summary_file, "w", encoding="utf-8") as f:
        f.write(f"52pojie 软件发布区 - 最新内容\n")
        f.write(f"抓取时间: {now}\n")
        f.write("=" * 60 + "\n\n")
        for i, post in enumerate(posts[:30], 1):
            f.write(f"[{i}] {post.title}\n")
            f.write(f"    作者: {post.author}  |  时间: {post.publish_time}\n")
            f.write(f"    回复: {post.replies}  |  查看: {post.views}\n")
            f.write(f"    链接: {post.url}\n\n")


# ─── 主抓取逻辑 ────────────────────────────────────────
def fetch_once() -> list[Post]:
    """执行一次抓取"""
    logger.info("启动浏览器...")
    page = ChromiumPage()
    page.set.ua("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36")

    try:
        logger.info(f"正在访问: {CONFIG['url']}")
        page.get(CONFIG["url"])
        # 等待页面加载完成（WAF 挑战通过后才会显示内容）
        page.wait.load_start(15)
        time.sleep(2)  # 额外等待确保内容渲染

        posts = []
        for page_num in range(1, CONFIG["max_pages"] + 1):
            logger.info(f"解析第 {page_num} 页...")
            page_posts = parse_posts(page, page_num)
            posts.extend(page_posts)
            if page_num < CONFIG["max_pages"]:
                next_btn = page.ele("tag:a@text=下一页", timeout=5)
                if next_btn:
                    next_btn.click()
                    page.wait.load_start(10)
                    time.sleep(2)

        if not posts:
            logger.warning("未解析到任何帖子，尝试备用方案...")
            posts = parse_posts_fallback(page)

        logger.info(f"共抓取到 {len(posts)} 条帖子")
        for i, p in enumerate(posts[:5], 1):
            logger.info(f"  {i}. {p.title[:50]}...")
        return posts

    except Exception as e:
        logger.error(f"抓取失败: {e}", exc_info=True)
        return []
    finally:
        page.quit()


# ─── 定时循环 ──────────────────────────────────────────
def run_loop():
    """定时循环执行"""
    logger.info("=" * 50)
    logger.info("52pojie 爬虫启动")
    logger.info(f"目标: {CONFIG['url']}")
    logger.info(f"间隔: {CONFIG['interval_minutes']} 分钟")
    logger.info(f"保存目录: {CONFIG['save_dir']}")
    logger.info("=" * 50)

    while True:
        try:
            posts = fetch_once()
            if posts:
                now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                save_data(CONFIG["save_dir"], posts, now)
                save_latest_summary(CONFIG["save_dir"], posts)
                logger.info(f"✓ 完成于 {now}")
            else:
                logger.warning("本次未抓取到数据")
        except Exception as e:
            logger.error(f"循环异常: {e}", exc_info=True)

        if CONFIG["run_once"]:
            break

        interval_sec = CONFIG["interval_minutes"] * 60
        logger.info(f"等待 {CONFIG['interval_minutes']} 分钟后下次抓取...")
        time.sleep(interval_sec)


# ─── 入口 ──────────────────────────────────────────────
if __name__ == "__main__":
    run_loop()
