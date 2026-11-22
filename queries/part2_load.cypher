// queries/part2_load.cypher
// Запуск: docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 -f /queries/part2_load.cypher
// Скрипт ідемпотентний: MERGE + IF NOT EXISTS → повторний запуск не створює дублікатів.

// ============================================================================
// 0. Обмеження унікальності (= індекси) — ДО завантаження.
//    Uniqueness constraint автоматично створює range-індекс по властивості,
//    тож MERGE/MATCH за ключем працюють через індекс, а не через повний скан лейбла.
//    Плюс БД сама гарантує, що двох User з однаковим userId не буде.
// ============================================================================
CREATE CONSTRAINT user_id IF NOT EXISTS FOR (u:User) REQUIRE u.userId IS UNIQUE;
CREATE CONSTRAINT movie_id IF NOT EXISTS FOR (m:Movie) REQUIRE m.movieId IS UNIQUE;
CREATE CONSTRAINT genre_name IF NOT EXISTS FOR (g:Genre) REQUIRE g.name IS UNIQUE;

// Додаткові індекси під запити частини 3
CREATE INDEX movie_year IF NOT EXISTS FOR (m:Movie) ON (m.year);
CREATE INDEX rated_rating IF NOT EXISTS FOR ()-[r:RATED]-() ON (r.rating);

// Чекаємо, поки індекси перейдуть у стан ONLINE
CALL db.awaitIndexes(300);

// ============================================================================
// 1. Користувачі (6 040) — одна транзакція, обсяг малий
// ============================================================================
LOAD CSV WITH HEADERS FROM 'file:///users.csv' AS row
MERGE (u:User {userId: toInteger(row.userId)})
SET u.gender         = row.gender,
    u.age            = toInteger(row.age),
    u.ageGroup       = row.ageGroup,
    u.occupation     = toInteger(row.occupation),
    u.occupationName = row.occupationName;

// ============================================================================
// 2. Фільми (3 883) + жанри (18) + ребра HAS_GENRE
//    genres у CSV — рядок "Action|Adventure|Thriller" → split → UNWIND
// ============================================================================
LOAD CSV WITH HEADERS FROM 'file:///movies.csv' AS row
MERGE (m:Movie {movieId: toInteger(row.movieId)})
SET m.title = row.title,
    m.year  = toInteger(row.year)
WITH m, row
UNWIND split(row.genres, '|') AS genreName
MERGE (g:Genre {name: genreName})
MERGE (m)-[:HAS_GENRE]->(g);

// ============================================================================
// 3. Оцінки (1 000 209 ребер RATED) — батчами через apoc.periodic.iterate
//    - перший запит лише СТРІМИТЬ рядки CSV;
//    - другий виконується для кожного батча в окремій транзакції;
//    - MATCH (не MERGE) для вузлів: вони вже існують, а MATCH по унікальному
//      індексу — найдешевша операція;
//    - MERGE для ребра — щоб повторний запуск не подвоїв оцінки;
//    - parallel:false — паралельні батчі можуть одночасно брати lock на того самого
//      User/Movie і впасти з deadlock; виграш у швидкості тут не вартий ризику.
// ============================================================================
CALL apoc.periodic.iterate(
  "LOAD CSV WITH HEADERS FROM 'file:///ratings.csv' AS row RETURN row",
  "MATCH (u:User  {userId:  toInteger(row.userId)})
   MATCH (m:Movie {movieId: toInteger(row.movieId)})
   MERGE (u)-[r:RATED]->(m)
   SET r.rating    = toInteger(row.rating),
       r.timestamp = toInteger(row.timestamp)",
  {batchSize: 10000, parallel: false}
)
YIELD batches, total, timeTaken, committedOperations, failedOperations, errorMessages
RETURN batches, total, timeTaken, committedOperations, failedOperations, errorMessages;

// ============================================================================
// 4. Перевірка
// ============================================================================
MATCH (u:User) RETURN count(u) AS users;
MATCH (m:Movie) RETURN count(m) AS movies;
MATCH (g:Genre) RETURN count(g) AS genres;
MATCH ()-[r:RATED]->() RETURN count(r) AS ratings;
MATCH ()-[h:HAS_GENRE]->() RETURN count(h) AS has_genre;
SHOW INDEXES YIELD name, type, entityType, labelsOrTypes, properties, state
RETURN name, type, entityType, labelsOrTypes, properties, state;
