#!/usr/bin/env python3
"""Как устроена дельта ГАР: оглавление и примеры записей без скачивания архива целиком.

Использование:
  python3 gar_delta_probe.py [--insecure] [--regions 43 11] [--versions 2] [--source <URL или zip дельты> ...]

Без --source берёт из API ФНС (GetAllDownloadFileInfo) последние --versions выгрузок с дельтой;
если API недоступен — ищет дельты за последние три недели на файловом сервере
fias-file.nalog.ru/downloads/<ГГГГ.ММ.ДД>/gar_delta_xml.zip.
Для URL читает только оглавление zip и файлы выбранных субъектов (HTTP Range). Нужен только
Python 3.8+, без сторонних библиотек. Отчёт печатается и сохраняется в gar_delta_probe.txt —
этот файл и нужно прислать. --insecure отключает проверку сертификата (у ФНС сертификат
российского УЦ).
"""
import argparse, datetime, io, json, os, re, ssl, sys, traceback, zipfile, urllib.error, urllib.request
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

API = "https://fias.nalog.ru/WebServices/Public/GetAllDownloadFileInfo"
FILES = "https://fias-file.nalog.ru/downloads/{date}/gar_delta_xml.zip"
# Файлы субъекта, которые читает гем (минимальный набор), — по ним примеры записей
TABLES = ["ADDR_OBJ", "HOUSES", "ADM_HIERARCHY", "MUN_HIERARCHY", "ADDR_OBJ_PARAMS", "HOUSES_PARAMS"]
MAX_FILE = 64 << 20  # файлы субъекта больше этого (несжатые) не читаются целиком

parser = argparse.ArgumentParser()
parser.add_argument("--insecure", action="store_true")
parser.add_argument("--regions", nargs="+", default=["43", "11"])
parser.add_argument("--versions", type=int, default=2)
parser.add_argument("--source", nargs="+")
parser.add_argument("--timeout", type=int, default=30)
opts = parser.parse_args()
CTX = ssl._create_unverified_context() if opts.insecure else None
REPORT = os.path.abspath("gar_delta_probe.txt")
report = open(REPORT, "w", encoding="utf-8", buffering=1)  # построчно: файл виден и при прерывании
print(f"Отчёт пишется в {REPORT}")


def out(*parts):
    line = " ".join(str(p) for p in parts)
    print(line)
    report.write(line + "\n")


def http(url, rng=None):
    headers = {"Range": f"bytes={rng}"} if rng else {}
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), context=CTX, timeout=opts.timeout)


class RangeFile(io.RawIOBase):
    """Файл по HTTP Range: zipfile читает только нужные куски"""

    def __init__(self, url):
        self.url, self.pos = url, 0
        with http(url, "0-0") as r:
            if r.status != 206:
                raise OSError(f"сервер не поддерживает Range (HTTP {r.status})")
            self.size = int(r.headers["Content-Range"].rsplit("/", 1)[1])

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, offset, whence=0):
        self.pos = (offset, self.pos + offset, self.size + offset)[whence]
        return self.pos

    def readinto(self, buf):
        if self.pos >= self.size:
            return 0
        with http(self.url, f"{self.pos}-{min(self.pos + len(buf), self.size) - 1}") as r:
            data = r.read()
        buf[:len(data)] = data
        self.pos += len(data)
        return len(data)


def size(n): return f"{n / 1024**2:.2f} МБ" if n >= 1 << 20 else f"{n / 1024:.1f} КБ"


def table_of(name):
    """AS_HOUSES_20260115_<guid>.XML → HOUSES"""
    base = re.sub(r"_\d{8}_[^/]*$", "", name.rsplit("/", 1)[-1])
    return base[3:] if base.startswith("AS_") else base


def records(zf, info):
    with zf.open(info) as f:
        for _, elem in ET.iterparse(f, events=("end",)):
            if elem.attrib:
                yield dict(elem.attrib)
            elem.clear()


def probe(src):
    out("=" * 100)
    out("Архив:", src)
    raw = RangeFile(src) if src.startswith("http") else open(src, "rb")
    zf = zipfile.ZipFile(io.BufferedReader(raw, 1 << 20) if src.startswith("http") else raw)
    infos = zf.infolist()
    out(f"Файлов: {len(infos)}, сжато {size(sum(i.compress_size for i in infos))}, несжато {size(sum(i.file_size for i in infos))}")

    folders = defaultdict(list)
    for i in infos:
        folders[i.filename.rsplit("/", 1)[0] if "/" in i.filename else ""].append(i)
    out("Корень:", ", ".join(f"{i.filename} ({size(i.file_size)})" for i in folders.pop("", [])))
    if "version.txt" in zf.namelist():
        out("version.txt:", repr(zf.read("version.txt").decode("utf-8", "replace")))
    nested = [f for f in folders if "/" in f]
    out(f"Папок: {len(folders)}: {', '.join(sorted(folders))}" + (f"; вложенные: {nested}" if nested else ""))
    out("Файлов в папках:", dict(Counter(len(v) for v in folders.values())))

    for region in opts.regions:
        files = folders.get(region, [])
        out("-" * 100)
        out(f"Субъект {region}: {len(files)} файлов")
        for i in sorted(files, key=lambda i: i.filename):
            out(f"  {i.filename}  {size(i.file_size)}")
        for i in files:
            table = table_of(i.filename)
            if table not in TABLES:
                continue
            if i.file_size > MAX_FILE:
                out(f"  {table}: {size(i.file_size)} — больше {size(MAX_FILE)}, пропущен")
                continue
            describe(zf, i, table)


def describe(zf, info, table):
    rows = list(records(zf, info))
    out("")
    out(f"  [{table}] записей: {len(rows)}")
    if not rows:
        return
    for flag in ("ISACTUAL", "ISACTIVE", "CHANGEIDEND", "TYPEID", "OPERTYPEID"):
        values = Counter(r.get(flag) for r in rows)
        if any(values.keys()):
            out(f"    {flag}: {dict(values.most_common(12))}")
    out("    Атрибуты:", sorted({k for r in rows for k in r}))
    for r in rows[:3]:
        out("    пример:", json.dumps(r, ensure_ascii=False))

    by_object = defaultdict(list)
    for r in rows:
        if "OBJECTID" in r:
            by_object[r["OBJECTID"]].append(r)
    repeated = {k: v for k, v in by_object.items() if len(v) > 1}
    out(f"    OBJECTID: {len(by_object)}, из них с несколькими записями в файле: {len(repeated)}")
    for object_id, items in list(repeated.items())[:2]:
        out(f"    записи объекта {object_id}:")
        for r in items:
            out("      ", json.dumps(r, ensure_ascii=False))

    if table.endswith("HIERARCHY"):
        moved = [k for k, v in repeated.items() if len({r.get("PATH") for r in v}) > 1]
        out(f"    объектов с разным PATH в дельте (перенос?): {len(moved)}")
        for object_id in moved[:3]:
            inside = sum(1 for r in rows if r.get("OBJECTID") != object_id and f".{object_id}." in f".{r.get('PATH', '')}.")
            out(f"      {object_id}: записей потомков с ним в PATH — {inside}")


def versions():
    try:
        with http(API) as r:
            data = json.load(r)
    except (OSError, ValueError) as e:
        out(f"API {API} недоступен ({e}): ищу дельты на файловом сервере")
        return files_server()
    out("Ключи записи API:", sorted(data[0].keys()) if data else "пусто")
    data.sort(key=lambda v: v.get("VersionId", 0))
    out("Последние выгрузки (VersionId, Date, есть ли дельта):")
    for v in data[-10:]:
        out(f"  {v.get('VersionId')}  {v.get('Date')}  дельта: {v.get('GarXMLDeltaURL') or '—'}")
    ids = [v.get("VersionId") for v in data]
    out("Подряд ли VersionId (пропуски дат — норма, выгрузки не ежедневные):", ids[-10:])
    return [v["GarXMLDeltaURL"] for v in data if v.get("GarXMLDeltaURL")][-opts.versions:]


def files_server():
    """Дельты за последние 21 день по шаблону FILES (выгрузки — по вторникам и пятницам)"""
    found = []
    today = datetime.date.today()
    for days in range(21):
        url = FILES.format(date=(today - datetime.timedelta(days)).strftime("%Y.%m.%d"))
        try:
            with http(url, "0-0") as r:
                out(f"  {url}: HTTP {r.status}, {r.headers.get('Content-Range')}")
                found.append(url)
        except urllib.error.HTTPError as e:
            out(f"  {url}: HTTP {e.code}")
        except OSError as e:
            out(f"  {url}: {e} — файловый сервер недоступен")
            break
        if len(found) == opts.versions:
            break
    return sorted(found)


try:
    sources = opts.source or versions()
    if not sources:
        out("Дельты не найдены. Скачайте gar_delta_xml.zip в браузере (fias.nalog.ru → Выгрузки)")
        out("и запустите: python3 gar_delta_probe.py --source gar_delta_xml.zip")
    for source in sources:
        try:
            probe(source)
        except (OSError, zipfile.BadZipFile) as e:
            out(f"Не удалось прочитать {source}: {e}")
except BaseException:
    out(traceback.format_exc())  # любая ошибка или Ctrl+C — тоже в отчёт
    sys.exit(1)
finally:
    report.close()
    print(f"\nОтчёт сохранён в {REPORT}")
