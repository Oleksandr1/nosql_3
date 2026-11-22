# convert.py — запустіть один раз перед завантаженням:  python convert.py
#
# Що змінено відносно шаблону з умови:
# 1. Якщо .dat-файлів немає — архів ml-1m.zip завантажується й розпаковується автоматично.
# 2. Рік винесено з назви в окрему колонку: "Toy Story (1995)" → title="Toy Story", year=1995.
#    Інакше в Cypher довелося б парсити рядок регулярками при кожному запиті.
# 3. До users.csv додано зрозумілі назви вікової групи й професії (коди з README датасету).
# 4. Перевірка кількості рядків наприкінці — щоб одразу побачити, якщо щось загубилось.
import csv
import io
import os
import re
import urllib.request
import zipfile

URL = "https://files.grouplens.org/datasets/movielens/ml-1m.zip"
SRC_DIR = "ml-1m"
OUT_DIR = "import"

AGE_GROUPS = {
    1: "Under 18", 18: "18-24", 25: "25-34", 35: "35-44",
    45: "45-49", 50: "50-55", 56: "56+",
}
OCCUPATIONS = {
    0: "other", 1: "academic/educator", 2: "artist", 3: "clerical/admin",
    4: "college/grad student", 5: "customer service", 6: "doctor/health care",
    7: "executive/managerial", 8: "farmer", 9: "homemaker", 10: "K-12 student",
    11: "lawyer", 12: "programmer", 13: "retired", 14: "sales/marketing",
    15: "scientist", 16: "self-employed", 17: "technician/engineer",
    18: "tradesman/craftsman", 19: "unemployed", 20: "writer",
}
TITLE_YEAR = re.compile(r"^(.*)\s+\((\d{4})\)\s*$")


def ensure_dataset():
    if os.path.exists(os.path.join(SRC_DIR, "ratings.dat")):
        return
    print(f"Завантажуємо {URL} ...")
    with urllib.request.urlopen(URL) as resp:
        zipfile.ZipFile(io.BytesIO(resp.read())).extractall(".")
    print("Розпаковано в ml-1m/")


def read_dat(name: str):
    # Роздільник «::», кодування Latin-1 (у назвах є é, ü, ñ тощо)
    with open(os.path.join(SRC_DIR, name), encoding="latin-1") as f:
        for line in f:
            line = line.rstrip("\n")
            if line:
                yield line.split("::")


def write_csv(name: str, header: list, rows) -> int:
    n = 0
    with open(os.path.join(OUT_DIR, name), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)   # csv.writer сам бере в лапки назви з комами: "Usual Suspects, The"
        w.writerow(header)
        for row in rows:
            w.writerow(row)
            n += 1
    return n


def movies():
    for movie_id, raw_title, genres in read_dat("movies.dat"):
        m = TITLE_YEAR.match(raw_title)
        title, year = (m.group(1), m.group(2)) if m else (raw_title, "")
        yield [movie_id, title, year, genres]


def users():
    for user_id, gender, age, occupation, _zip in read_dat("users.dat"):
        yield [user_id, gender, age, AGE_GROUPS[int(age)],
               occupation, OCCUPATIONS[int(occupation)]]


def ratings():
    yield from read_dat("ratings.dat")   # userId, movieId, rating, timestamp


if __name__ == "__main__":
    ensure_dataset()
    os.makedirs(OUT_DIR, exist_ok=True)
    counts = {
        "movies.csv": write_csv("movies.csv", ["movieId", "title", "year", "genres"], movies()),
        "users.csv": write_csv("users.csv", ["userId", "gender", "age", "ageGroup",
                                             "occupation", "occupationName"], users()),
        "ratings.csv": write_csv("ratings.csv", ["userId", "movieId", "rating", "timestamp"], ratings()),
    }
    expected = {"movies.csv": 3883, "users.csv": 6040, "ratings.csv": 1000209}
    for name, n in counts.items():
        status = "OK" if n == expected[name] else f"ОЧІКУВАЛОСЬ {expected[name]}"
        print(f"{name:12s} {n:>9,} рядків  {status}")
