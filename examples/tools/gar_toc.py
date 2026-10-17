#!/usr/bin/env python3
"""Оглавление архива ГАР без распаковки.

Использование:
  python3 gar_toc.py <путь к zip или URL> [коды субъектов...] [--insecure] [--extract <zip>]

--extract сохраняет в новый zip корневые файлы и папки субъектов (для URL — только их сжатые
данные по HTTP Range, без скачивания архива целиком): проверочный архив двух субъектов.

Для URL читается только оглавление zip и несколько КБ из файлов (HTTP Range), архив не скачивается.
--insecure отключает проверку сертификата (только для отладки).
Результат — в docs/gar_archive_structure.md.
"""
import http.client as http_client, io, re, ssl, sys, time, zipfile, urllib.error, urllib.request
from collections import defaultdict

argv = sys.argv[1:]
EXTRACT = None
if "--extract" in argv:
    at = argv.index("--extract")
    EXTRACT = argv[at + 1]
    del argv[at:at + 2]
args = [a for a in argv if a != "--insecure"]
CTX = ssl._create_unverified_context() if "--insecure" in argv else None
SRC, REGIONS = args[0], args[1:] or ["43", "11"]


def fetch(url, rng, attempts=8):
    """Кусок файла (статус, заголовки, данные); файловый сервер ФНС временами отвечает 5xx или
    рвёт связь — повтор с растущей паузой"""
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"Range": f"bytes={rng}"})
            with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
                return r.status, r.headers, r.read()
        except (urllib.error.HTTPError, OSError, http_client.HTTPException) as e:
            if attempt == attempts - 1 or (isinstance(e, urllib.error.HTTPError) and e.code < 500 and e.code != 429):
                raise
            print(f"  повтор через {2 ** attempt} с: {e}", file=sys.stderr, flush=True)
            time.sleep(2 ** attempt)


class RangeFile(io.RawIOBase):
    def __init__(self, url):
        self.url, self.pos, self.requests = url, 0, 0
        status, headers, _ = fetch(url, "0-0")
        if status != 206:
            sys.exit(f"Сервер не поддерживает Range (HTTP {status})")
        self.size = int(headers["Content-Range"].rsplit("/", 1)[1])

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, offset, whence=0):
        self.pos = (offset, self.pos + offset, self.size + offset)[whence]
        return self.pos

    def readinto(self, buf):
        if self.pos >= self.size:
            return 0
        _, _, data = fetch(self.url, f"{self.pos}-{min(self.pos + len(buf), self.size) - 1}")
        self.requests += 1
        buf[:len(data)] = data
        self.pos += len(data)
        return len(data)


def gb(n): return f"{n / 1024**3:9.3f} ГБ"
def table(name): return re.sub(r"_\d{8}_[^/]*$", "", name.rsplit("/", 1)[-1])
def head(info, n=700):
    with zf.open(info) as f:
        return f.read(n).decode("utf-8", "replace")


remote = SRC.startswith("http")
raw = RangeFile(SRC) if remote else open(SRC, "rb")
zf = zipfile.ZipFile(io.BufferedReader(raw, (8 if EXTRACT else 1) << 20) if remote else raw)
items = [i for i in zf.infolist() if not i.is_dir()]
root = [i for i in items if "/" not in i.filename]
folders = defaultdict(list)
for i in items:
    if "/" in i.filename:
        folders[i.filename.split("/", 1)[0]].append(i)

print(f"Источник: {SRC}")
print(f"Файлов: {len(items)}, сжато {gb(sum(i.compress_size for i in items))}, несжато {gb(sum(i.file_size for i in items))}")
print(f"Файлов глубже одного уровня папок: {sum(1 for i in items if i.filename.count('/') > 1)}")
print("\n== Корень (имя, несжато байт)")
for i in sorted(root, key=lambda i: i.filename):
    print(f"  {i.filename:75} {i.file_size:>16,}")
print("\n== Папки (папка, файлов, сжато, несжато)")
for name in sorted(folders):
    fs = folders[name]
    print(f"  {name:6} {len(fs):3} {gb(sum(i.compress_size for i in fs))} {gb(sum(i.file_size for i in fs))}")
print("\n== Таблицы по всем папкам (префикс, файлов, несжато всего, самый большой файл)")
stats = defaultdict(list)
for fs in folders.values():
    for i in fs:
        stats[table(i.filename)].append(i.file_size)
for name, sizes in sorted(stats.items(), key=lambda kv: -sum(kv[1])):
    print(f"  {name:28} {len(sizes):4} {gb(sum(sizes))} {gb(max(sizes))}")
for region in REGIONS:
    print(f"\n== Папка {region} (имя, сжато, несжато)")
    for i in sorted(folders.get(region, []), key=lambda i: i.filename):
        print(f"  {i.filename:75} {i.compress_size:>14,} {i.file_size:>14,}")
print("\n== Образцы")
for i in root:
    if i.filename.lower() == "version.txt" or table(i.filename) == "AS_PARAM_TYPES":
        print(f"--- {i.filename}\n{head(i, 6000)}\n")
for i in folders.get(REGIONS[0], []):
    if table(i.filename) in ("AS_HOUSES", "AS_ADDR_OBJ", "AS_ADDR_OBJ_PARAMS", "AS_ADM_HIERARCHY", "AS_REESTR_OBJECTS"):
        print(f"--- {i.filename}\n{head(i)}\n")
if EXTRACT:
    chosen = root + [i for r in REGIONS for i in folders.get(r, [])]
    with zipfile.ZipFile(EXTRACT, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as out:
        for n, i in enumerate(chosen, 1):
            print(f"  [{n}/{len(chosen)}] {i.filename} ({gb(i.compress_size)} сжато)", flush=True)
            info = zipfile.ZipInfo(i.filename, i.date_time)
            info.compress_type = zipfile.ZIP_DEFLATED
            with zf.open(i) as src, out.open(info, "w", force_zip64=True) as dst:
                while chunk := src.read(1 << 20):
                    dst.write(chunk)
    print(f"Сохранено: {EXTRACT}")
if remote:
    print(f"HTTP-запросов: {raw.requests}")
