// queries/part3.cypher
// Запуск: docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 -f /queries/part3.cypher
// Для скриншотів — копіюйте запити по одному в Neo4j Browser (http://localhost:7474).

// ============================================================================
// Запит 1. Фільми жанру Thriller із середнім рейтингом > 4.0
//   Поріг кількості оцінок (>= 30): без нього у топ потрапляють фільми з 1–2 оцінками «5»,
//   і «середній рейтинг» нічого не означає. Без порогу — див. варіант 1b.
// ============================================================================
MATCH (g:Genre {name: 'Thriller'})<-[:HAS_GENRE]-(m:Movie)<-[r:RATED]-()
WITH m, avg(r.rating) AS avgRating, count(r) AS numRatings
WHERE avgRating > 4.0 AND numRatings >= 30
RETURN m.title AS title, m.year AS year,
       round(avgRating, 2) AS avgRating, numRatings
ORDER BY avgRating DESC, numRatings DESC;

// 1b. Те саме без порогу кількості — для порівняння в README
MATCH (g:Genre {name: 'Thriller'})<-[:HAS_GENRE]-(m:Movie)<-[r:RATED]-()
WITH m, avg(r.rating) AS avgRating, count(r) AS numRatings
WHERE avgRating > 4.0
RETURN count(m) AS thrillersAbove4, min(numRatings) AS minRatings, max(numRatings) AS maxRatings;

// ============================================================================
// Запит 2. Користувачі, які поставили «5» більш ніж 50 фільмам
//   Фільтр r.rating = 5 застосовується ДО агрегації — рахуємо лише потрібні ребра.
// ============================================================================
MATCH (u:User)-[r:RATED]->(:Movie)
WHERE r.rating = 5
WITH u, count(r) AS fives
WHERE fives > 50
RETURN u.userId AS userId, u.gender AS gender, u.ageGroup AS ageGroup,
       u.occupationName AS occupation, fives
ORDER BY fives DESC
LIMIT 25;

// 2b. Скільки всього таких користувачів
MATCH (u:User)-[r:RATED]->(:Movie)
WHERE r.rating = 5
WITH u, count(r) AS fives
WHERE fives > 50
RETURN count(u) AS usersWithMoreThan50Fives;

// ============================================================================
// Запит 3. Фільми, які обидва користувачі (1 і 2) оцінили високо (>= 4)
//   Один патерн «u1 → m ← u2»: Neo4j знаходить обох через індекс userId
//   і перетинає їхні сусідства — без JOIN-ів.
// ============================================================================
MATCH (u1:User {userId: 1})-[r1:RATED]->(m:Movie)<-[r2:RATED]-(u2:User {userId: 2})
WHERE r1.rating >= 4 AND r2.rating >= 4
RETURN m.title AS title, m.year AS year, r1.rating AS user1, r2.rating AS user2
ORDER BY r1.rating + r2.rating DESC, title;

// ============================================================================
// Запит 4. Жанри, чиї фільми стабільно отримують високі оцінки
//   «Стабільно» = високе середнє + велика кількість оцінок + невеликий розкид
//   (stDev) + частка оцінок >= 4. Фільм із кількома жанрами враховується в кожному.
// ============================================================================
зроб

// ============================================================================
// Запит 5. «Користувачі зі схожими смаками також дивилися» (user-based CF)
//   1) сусіди: хто високо оцінив ті самі фільми, що й наш користувач;
//   2) беремо 50 найсхожіших (за кількістю спільних високих оцінок);
//   3) їхні високо оцінені фільми, яких наш користувач ще НЕ оцінював;
//   4) ранжуємо за кількістю «голосів» сусідів і середньою оцінкою.
//   WITH 1 AS targetId — замість :param, щоб файл однаково працював у Browser і cypher-shell.
// ============================================================================
WITH 1 AS targetId
MATCH (me:User {userId: targetId})-[r1:RATED]->(m:Movie)<-[r2:RATED]-(other:User)
WHERE r1.rating >= 4 AND r2.rating >= 4 AND other <> me
WITH me, other, count(m) AS commonHigh
ORDER BY commonHigh DESC
LIMIT 50
MATCH (other)-[r:RATED]->(rec:Movie)
WHERE r.rating >= 4 AND NOT (me)-[:RATED]->(rec)
WITH rec, count(DISTINCT other) AS votes, avg(r.rating) AS avgNeighbourRating,
     sum(commonHigh) AS similarityScore
WHERE votes >= 5
RETURN rec.title AS title, rec.year AS year, votes,
       round(avgNeighbourRating, 2) AS avgNeighbourRating, similarityScore
ORDER BY votes DESC, avgNeighbourRating DESC
LIMIT 10;

// ============================================================================
// Запит 6. Найкоротший ланцюжок між двома користувачами через спільні фільми
//   [:RATED*..6] без напрямку: User → Movie ← User → Movie ← User ...
//   Верхня межа обов'язкова: без неї shortestPath може обходити величезну частину графа.
// ============================================================================
MATCH (u1:User {userId: 1}), (u2:User {userId: 2})
MATCH p = shortestPath((u1)-[:RATED*..6]-(u2))
RETURN length(p) AS pathLength,
       [n IN nodes(p) | coalesce(n.title, 'User ' + toString(n.userId))] AS chain;

// 6b. Те саме, але лише через ВИСОКІ оцінки обох сторін (≥ 4) — «спільний смак», а не просто перегляд
MATCH (u1:User {userId: 1}), (u2:User {userId: 2})
MATCH p = shortestPath((u1)-[:RATED*..6]-(u2))
WHERE all(r IN relationships(p) WHERE r.rating >= 4)
RETURN length(p) AS pathLength,
       [n IN nodes(p) | coalesce(n.title, 'User ' + toString(n.userId))] AS chain;

// 6c. Чи бувають пари з довжиною шляху > 2? Шукаємо користувачів БЕЗ жодного спільного фільму з userId=1
MATCH (a:User {userId: 1})-[:RATED]->(:Movie)<-[:RATED]-(b:User)
WITH a, collect(DISTINCT b) AS neighbours
MATCH (c:User)
WHERE c <> a AND NOT c IN neighbours
RETURN count(c) AS usersWithoutCommonMovie, collect(c.userId)[..10] AS sample;

// 6d. Довжина шляху до першого такого користувача (порожньо, якщо 6c повернув 0)
MATCH (u1:User {userId: 1})-[:RATED]->(:Movie)<-[:RATED]-(b:User)
WITH u1, collect(DISTINCT b) AS neighbours
MATCH (far:User)
WHERE far <> u1 AND NOT far IN neighbours
WITH u1, far LIMIT 1
MATCH p = shortestPath((u1)-[:RATED*..8]-(far))
RETURN far.userId AS farUser, length(p) AS pathLength,
       [n IN nodes(p) | coalesce(n.title, 'User ' + toString(n.userId))] AS chain;
