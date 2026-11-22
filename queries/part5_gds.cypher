// queries/part5_gds.cypher  (додаткова частина, не оцінюється)
// Запуск: docker exec -i neo4j_movielens cypher-shell -u neo4j -p password123 -f /queries/part5_gds.cypher
// Запити візуалізації (позначені VIZ) запускайте в Neo4j Browser — він малює граф.
//
// ВІДХИЛЕННЯ ВІД ШАБЛОНУ (детально — README, розділ 7.0):
// Шаблон будує ребра CO_RATED / SIMILAR «в лоб»: усі пари через спільні оцінки,
// count(), ORDER BY, LIMIT 50000. На повних даних це сотні мільйонів проміжних рядків
// і мільйони пар у пам'яті, плюс LIMIT по глобальному топу віддає всі ребра кільком
// «важким» користувачам, а решта графа лишається без ребер.
// Тут ці ребра будує GDS Node Similarity (Jaccard, topK сусідів для КОЖНОГО вузла):
// той самий зміст «схожі через спільні високі оцінки», але кожен вузол отримує ребра.
// Шаблонний варіант збережено нижче в коментарях (Варіант A) для порівняння.
//
// Повне прибирання після частини 5 (виконати вручну, щоб повернути граф до стану після частини 2):
//   MATCH ()-[s:SIMILAR]->() DELETE s;
//   MATCH (n) WHERE n.pagerank IS NOT NULL OR n.community IS NOT NULL REMOVE n.pagerank, n.community;

// ---- прибирання з попередніх запусків (ідемпотентність) -------------------
CALL gds.graph.drop('movieUserHigh', false) YIELD graphName RETURN graphName;
CALL gds.graph.drop('userMovieHigh', false) YIELD graphName RETURN graphName;
CALL gds.graph.drop('movieGraph', false) YIELD graphName RETURN graphName;
CALL gds.graph.drop('userSimilarity', false) YIELD graphName RETURN graphName;
CALL gds.graph.drop('userGraph', false) YIELD graphName RETURN graphName;
MATCH ()-[co:CO_RATED]->() DELETE co;
MATCH ()-[s:SIMILAR]->() DELETE s;

// ============================================================================
// 5.1. PageRank на графі фільмів
// ============================================================================

// Крок 1 (Варіант B, використовується): двочастковий граф Movie → User лише з оцінок >= 4.
// Cypher-агрегація gds.graph.project дозволяє відфільтрувати ребра за властивістю.
MATCH (m:Movie)<-[r:RATED]-(u:User)
WHERE r.rating >= 4
WITH gds.graph.project('movieUserHigh', m, u,
       {sourceNodeLabels: labels(m), targetNodeLabels: labels(u)}) AS g
RETURN g.graphName AS graph, g.nodeCount AS nodes, g.relationshipCount AS rels;

// Node Similarity порівнює фільми за множинами користувачів, що високо їх оцінили (Jaccard).
// degreeCutoff: 20 — фільм має понад 20 високих оцінок (аналог фільтра «> 20» у шаблоні).
// topK: 10 — для кожного фільму 10 найсхожіших → ребро CO_RATED {weight: jaccard}.
CALL gds.nodeSimilarity.write('movieUserHigh', {
  topK: 10, degreeCutoff: 20, similarityCutoff: 0.05,
  writeRelationshipType: 'CO_RATED', writeProperty: 'weight'
})
YIELD nodesCompared, relationshipsWritten, similarityDistribution
RETURN nodesCompared, relationshipsWritten,
       round(similarityDistribution.mean, 3) AS meanJaccard,
       round(similarityDistribution.max, 3) AS maxJaccard;

/* Крок 1 (Варіант A, як у шаблоні) — НЕ запускається за замовчуванням.
   Ризикує впасти по пам'яті при heap < 4G; щоб спробувати — підвищте поріг до r.rating = 5.
MATCH (m1:Movie)<-[r1:RATED]-(u:User)-[r2:RATED]->(m2:Movie)
WHERE r1.rating >= 4 AND r2.rating >= 4 AND m1.movieId < m2.movieId
WITH m1, m2, count(u) AS weight
WHERE COUNT { (m1)<-[:RATED]-() } > 20 AND COUNT { (m2)<-[:RATED]-() } > 20
WITH m1, m2, weight ORDER BY weight DESC LIMIT 50000
MERGE (m1)-[co:CO_RATED]-(m2)
SET co.weight = weight;
*/

// Крок 2: проєкція фільм–фільм (як у шаблоні)
CALL gds.graph.project(
  'movieGraph',
  'Movie',
  { CO_RATED: { orientation: 'UNDIRECTED', properties: 'weight' } }
)
YIELD graphName, nodeCount, relationshipCount
RETURN graphName, nodeCount, relationshipCount;

// Крок 3: PageRank (зважений). Записуємо score у вузли — для візуалізації та порівняння.
CALL gds.pageRank.write('movieGraph', {
  relationshipWeightProperty: 'weight',
  dampingFactor: 0.85, maxIterations: 40,
  writeProperty: 'pagerank'
})
YIELD nodePropertiesWritten, ranIterations, didConverge
RETURN nodePropertiesWritten, ranIterations, didConverge;

// 3a. Топ-20 за PageRank поруч із популярністю (кількістю оцінок) і середньою оцінкою
MATCH (m:Movie) WHERE m.pagerank IS NOT NULL
WITH m ORDER BY m.pagerank DESC LIMIT 20
MATCH (m)<-[r:RATED]-()
WITH m, count(r) AS numRatings, avg(r.rating) AS avgRating
RETURN m.title AS title, m.year AS year, round(m.pagerank, 3) AS pagerank,
       numRatings, round(avgRating, 2) AS avgRating,
       [(m)-[:HAS_GENRE]->(g) | g.name] AS genres
ORDER BY pagerank DESC;

// 3b. Наскільки PageRank ≠ популярність: ранг за PageRank vs ранг за кількістю оцінок (топ-20 PR)
MATCH (m:Movie) WHERE m.pagerank IS NOT NULL
WITH m, COUNT { (m)<-[:RATED]-() } AS numRatings
ORDER BY numRatings DESC
WITH collect(m) AS byPopularity
MATCH (m:Movie) WHERE m.pagerank IS NOT NULL
WITH byPopularity, m ORDER BY m.pagerank DESC LIMIT 20
WITH byPopularity, collect(m) AS topPr
UNWIND range(0, size(topPr) - 1) AS i
WITH topPr[i] AS m, i + 1 AS prRank, byPopularity
RETURN m.title AS title, prRank,
       apoc.coll.indexOf(byPopularity, m) + 1 AS popularityRank;

// VIZ 5.1: топ-15 фільмів за PageRank і ребра CO_RATED між ними (Neo4j Browser)
MATCH (m:Movie) WHERE m.pagerank IS NOT NULL
WITH m ORDER BY m.pagerank DESC LIMIT 15
WITH collect(m) AS top
MATCH p = (a:Movie)-[:CO_RATED]-(b:Movie)
WHERE a IN top AND b IN top
RETURN p;

// Крок 4: видаляємо проєкції та тимчасові ребра
CALL gds.graph.drop('movieGraph') YIELD graphName RETURN graphName;
CALL gds.graph.drop('movieUserHigh') YIELD graphName RETURN graphName;
MATCH ()-[co:CO_RATED]->() DELETE co;

// ============================================================================
// 5.2. Спільноти користувачів (Louvain)
// ============================================================================

// Крок 1 (Варіант B): User → Movie з оцінок >= 4 → Node Similarity між користувачами
MATCH (u:User)-[r:RATED]->(m:Movie)
WHERE r.rating >= 4
WITH gds.graph.project('userMovieHigh', u, m,
       {sourceNodeLabels: labels(u), targetNodeLabels: labels(m)}) AS g
RETURN g.graphName AS graph, g.nodeCount AS nodes, g.relationshipCount AS rels;

CALL gds.nodeSimilarity.write('userMovieHigh', {
  topK: 10, degreeCutoff: 10, similarityCutoff: 0.05,
  writeRelationshipType: 'SIMILAR', writeProperty: 'weight'
})
YIELD nodesCompared, relationshipsWritten, similarityDistribution
RETURN nodesCompared, relationshipsWritten,
       round(similarityDistribution.mean, 3) AS meanJaccard,
       round(similarityDistribution.max, 3) AS maxJaccard;

CALL gds.graph.drop('userMovieHigh') YIELD graphName RETURN graphName;

// Вартість ребра для Dijkstra (5.3): чим схожіші користувачі, тим «коротше» ребро.
// Dijkstra МІНІМІЗУЄ суму ваг, тож подавати йому similarity напряму не можна.
MATCH ()-[s:SIMILAR]->() SET s.cost = 1.0 - s.weight;

/* Крок 1 (Варіант A, як у шаблоні) — для порівняння, за замовчуванням не запускається
MATCH (u1:User)-[r1:RATED]->(m:Movie)<-[r2:RATED]-(u2:User)
WHERE r1.rating >= 4 AND r2.rating >= 4 AND u1.userId < u2.userId
WITH u1, u2, count(m) AS weight ORDER BY weight DESC LIMIT 50000
MERGE (u1)-[sim:SIMILAR]-(u2)
SET sim.weight = weight;
*/

// Крок 2: проєкція (як у шаблоні)
CALL gds.graph.project(
  'userSimilarity',
  'User',
  { SIMILAR: { orientation: 'UNDIRECTED', properties: 'weight' } }
)
YIELD graphName, nodeCount, relationshipCount
RETURN graphName, nodeCount, relationshipCount;

// Крок 3: Louvain, результат записуємо в u.community
CALL gds.louvain.write('userSimilarity', {
  relationshipWeightProperty: 'weight',
  writeProperty: 'community'
})
YIELD communityCount, modularity, ranLevels, communityDistribution
RETURN communityCount, round(modularity, 4) AS modularity, ranLevels,
       communityDistribution.max AS largest, communityDistribution.p50 AS medianSize;

// 3a. 10 найбільших спільнот + частка від усіх користувачів
MATCH (u:User) WHERE u.community IS NOT NULL
WITH u.community AS community, count(*) AS size
ORDER BY size DESC LIMIT 10
RETURN community, size, round(100.0 * size / 6040, 1) AS pctUsers;

// 3b. Демографія 10 найбільших спільнот — перевірка, чи кластери відповідають «реальним» групам
MATCH (u:User) WHERE u.community IS NOT NULL
WITH u.community AS c, count(*) AS size ORDER BY size DESC LIMIT 10
WITH collect(c) AS topC
MATCH (u:User) WHERE u.community IN topC
WITH u.community AS community, count(*) AS size,
     round(100.0 * sum(CASE WHEN u.gender = 'F' THEN 1 ELSE 0 END) / count(*), 1) AS pctFemale,
     round(avg(u.age), 1) AS avgAgeCode
RETURN community, size, pctFemale, avgAgeCode
ORDER BY size DESC;

// Крок 4a. Топ-3 жанри кожної з 10 найбільших спільнот — за СИРОЮ кількістю високих оцінок.
// Очікувано скрізь Drama/Comedy: це просто найчисленніші жанри.
MATCH (u:User) WHERE u.community IS NOT NULL
WITH u.community AS c, count(*) AS size ORDER BY size DESC LIMIT 10
WITH collect(c) AS topC
MATCH (u:User)-[r:RATED]->(:Movie)-[:HAS_GENRE]->(g:Genre)
WHERE u.community IN topC AND r.rating >= 4
WITH u.community AS community, g.name AS genre, count(*) AS cnt
ORDER BY community, cnt DESC
WITH community, collect(genre)[..3] AS top3ByCount
RETURN community, top3ByCount;

// Крок 4b. Топ-3 жанри за LIFT = частка жанру в спільноті / частка жанру в усьому датасеті.
// lift > 1 — спільнота любить жанр більше, ніж «середній» користувач. Це і є «смак» кластера.
MATCH (:User)-[r:RATED]->(:Movie)-[:HAS_GENRE]->(g:Genre)
WHERE r.rating >= 4
WITH g.name AS genre, count(*) AS cnt
WITH collect([genre, cnt]) AS pairs, sum(cnt) AS total
WITH apoc.map.fromPairs([p IN pairs | [p[0], toFloat(p[1]) / total]]) AS globalShare
MATCH (u:User) WHERE u.community IS NOT NULL
WITH globalShare, u.community AS c, count(*) AS size ORDER BY size DESC LIMIT 10
WITH globalShare, collect(c) AS topC
MATCH (u:User)-[r:RATED]->(:Movie)-[:HAS_GENRE]->(g:Genre)
WHERE u.community IN topC AND r.rating >= 4
WITH globalShare, u.community AS community, g.name AS genre, count(*) AS cnt
WITH globalShare, community, collect({genre: genre, cnt: cnt}) AS rows, sum(cnt) AS total
UNWIND rows AS row
WITH community, row.genre AS genre,
     (toFloat(row.cnt) / total) / globalShare[row.genre] AS lift, row.cnt AS cnt
WHERE cnt >= 50
WITH community, genre, lift ORDER BY community, lift DESC
WITH community, collect(genre + ' (×' + toString(round(lift, 2)) + ')')[..3] AS top3ByLift
RETURN community, top3ByLift;

// VIZ 5.2: дві найбільші спільноти, по 25 користувачів, і ребра SIMILAR між ними (Neo4j Browser)
MATCH (u:User) WHERE u.community IS NOT NULL
WITH u.community AS c, count(*) AS size ORDER BY size DESC LIMIT 2
WITH collect(c) AS topC
UNWIND topC AS c
MATCH (u:User {community: c})
WITH c, collect(u)[..25] AS members
UNWIND members AS u
WITH collect(u) AS sample
MATCH p = (a:User)-[:SIMILAR]-(b:User)
WHERE a IN sample AND b IN sample
RETURN p;

// Крок 5: видаляємо проєкцію. Ребра SIMILAR НЕ видаляємо — вони потрібні для 5.3
// (шаблон видаляє їх і створює заново, що лише подвоює час).
CALL gds.graph.drop('userSimilarity') YIELD graphName RETURN graphName;

// ============================================================================
// 5.3. Найкоротший шлях між користувачами (Dijkstra)
// ============================================================================
CALL gds.graph.project(
  'userGraph',
  'User',
  { SIMILAR: { orientation: 'UNDIRECTED', properties: ['weight', 'cost'] } }
)
YIELD graphName, nodeCount, relationshipCount
RETURN graphName, nodeCount, relationshipCount;

// 3a. Dijkstra для кількох пар: зважений (cost = 1 − similarity) шлях і кількість хопів
UNWIND [[1, 2], [1, 3000], [1, 6040], [100, 5000], [4169, 1]] AS pair
MATCH (src:User {userId: pair[0]}), (tgt:User {userId: pair[1]})
CALL gds.shortestPath.dijkstra.stream('userGraph', {
  sourceNode: src, targetNode: tgt, relationshipWeightProperty: 'cost'
})
YIELD totalCost, nodeIds
RETURN pair[0] AS fromUser, pair[1] AS toUser,
       size(nodeIds) - 1 AS hops,
       size(nodeIds) - 2 AS intermediateUsers,
       round(totalCost, 3) AS totalCost,
       [id IN nodeIds | gds.util.asNode(id).userId] AS route;

// 3b. «Тісність світу»: незважені відстані (хопи) від 10 джерел до ВСІХ досяжних користувачів
UNWIND [1, 100, 500, 1000, 2000, 3000, 4000, 4169, 5000, 6000] AS sid
MATCH (src:User {userId: sid})
CALL gds.allShortestPaths.dijkstra.stream('userGraph', {sourceNode: src})
YIELD targetNode, totalCost
WHERE totalCost > 0            // без самого джерела
WITH sid, count(*) AS reachable, avg(totalCost) AS avgHops, max(totalCost) AS maxHops,
     percentileDisc(totalCost, 0.9) AS p90Hops
RETURN sid AS sourceUser, reachable, round(avgHops, 2) AS avgHops, p90Hops, maxHops
ORDER BY sourceUser;

// 3c. Зв'язність графа: скільки компонент і наскільки велика найбільша
CALL gds.wcc.stats('userGraph')
YIELD componentCount, componentDistribution
RETURN componentCount, componentDistribution.max AS largestComponent,
       componentDistribution.min AS smallestComponent;

// VIZ 5.3: шлях Dijkstra між userId 1 і 6040 як граф (Neo4j Browser)
MATCH (src:User {userId: 1}), (tgt:User {userId: 6040})
CALL gds.shortestPath.dijkstra.stream('userGraph', {
  sourceNode: src, targetNode: tgt, relationshipWeightProperty: 'cost'
})
YIELD path
RETURN path;

CALL gds.graph.drop('userGraph') YIELD graphName RETURN graphName;
