// queries/part4_supernodes.cypher
// Запуск: docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 -f /queries/part4_supernodes.cypher
//
// COUNT { (n)-[:TYPE]-() } — ступінь вузла за типом ребра. Для «щільних» вузлів
// (> 50 ребер) Neo4j зберігає лічильники по групах ребер, тому такий підрахунок
// не обходить самі ребра — запит дешевий навіть на супервузлах.

// ============================================================================
// Крок 1. Розподіл ступенів по кожному лейблу — що вважати «аномально великим»
//   Супервузол = ступінь у рази вищий за типовий (медіану) і за p99.
// ============================================================================
MATCH (m:Movie)
WITH COUNT { (m)<-[:RATED]-() } AS deg
RETURN 'Movie (вхідні RATED)' AS nodeType,
       count(*) AS nodes, round(avg(deg), 1) AS avgDegree,
       percentileDisc(deg, 0.5) AS median, percentileDisc(deg, 0.99) AS p99, max(deg) AS maxDegree
UNION ALL
MATCH (u:User)
WITH COUNT { (u)-[:RATED]->() } AS deg
RETURN 'User (вихідні RATED)' AS nodeType,
       count(*) AS nodes, round(avg(deg), 1) AS avgDegree,
       percentileDisc(deg, 0.5) AS median, percentileDisc(deg, 0.99) AS p99, max(deg) AS maxDegree
UNION ALL
MATCH (g:Genre)
WITH COUNT { (g)<-[:HAS_GENRE]-() } AS deg
RETURN 'Genre (вхідні HAS_GENRE)' AS nodeType,
       count(*) AS nodes, round(avg(deg), 1) AS avgDegree,
       percentileDisc(deg, 0.5) AS median, percentileDisc(deg, 0.99) AS p99, max(deg) AS maxDegree;

// 1a. Топ-10 фільмів за кількістю оцінок
MATCH (m:Movie)
WITH m, COUNT { (m)<-[:RATED]-() } AS degree
ORDER BY degree DESC
LIMIT 10
RETURN m.title AS title, m.year AS year, degree;

// 1b. Топ-10 користувачів за кількістю оцінок
MATCH (u:User)
WITH u, COUNT { (u)-[:RATED]->() } AS degree
ORDER BY degree DESC
LIMIT 10
RETURN u.userId AS userId, u.gender AS gender, u.ageGroup AS ageGroup,
       u.occupationName AS occupation, degree;

// 1c. Жанри: прямий ступінь (фільми) і «досяжність» (оцінки, до яких веде обхід через жанр)
MATCH (g:Genre)
WITH g, COUNT { (g)<-[:HAS_GENRE]-() } AS movies
CALL {
  WITH g
  MATCH (g)<-[:HAS_GENRE]-(:Movie)<-[r:RATED]-()
  RETURN count(r) AS reachableRatings
}
RETURN g.name AS genre, movies, reachableRatings,
       round(100.0 * reachableRatings / 1000209, 1) AS pctOfAllRatings
ORDER BY movies DESC;

// 1d. Вузли зі ступенем > середнє + 3σ — формальний критерій «аномальності»
MATCH (m:Movie)
WITH m, COUNT { (m)<-[:RATED]-() } AS deg
WITH collect({title: m.title, deg: deg}) AS rows, avg(deg) AS mu, stDev(deg) AS sigma
UNWIND rows AS row
WITH row, mu, sigma
WHERE row.deg > mu + 3 * sigma
RETURN count(*) AS supernodeMovies, round(mu + 3 * sigma) AS threshold,
       collect(row.title)[..10] AS examples;

// ============================================================================
// Крок 2. Наочно: ціна запиту через супервузол vs звичайний вузол
//   PROFILE показує db hits і кількість рядків на кожному кроці плану.
//   Порівняйте «American Beauty» (найпопулярніший) і фільм із ~медіанною кількістю оцінок.
// ============================================================================
PROFILE
MATCH (m:Movie {title: 'American Beauty'})<-[:RATED]-(u:User)-[:RATED]->(other:Movie)
RETURN count(*) AS twoHopRows;

PROFILE
MATCH (m:Movie)
WITH m, COUNT { (m)<-[:RATED]-() } AS deg
WHERE deg >= 120 AND deg <= 125
WITH m LIMIT 1
MATCH (m)<-[:RATED]-(u:User)-[:RATED]->(other:Movie)
RETURN m.title AS typicalMovie, count(*) AS twoHopRows;
