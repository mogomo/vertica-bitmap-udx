# Video: The Bitmap Database Inside Vertica Answers Faster Than ClickHouse's Own Bitmaps. We Measured Everything.

Storyboard and narration for a video of about 18 minutes (15 minutes of narration, 3 of live demo).
The video tells one story: a claim that every vendor makes ("one platform can do it all") is put
to a test that it could fail, the evidence turns against it more than once, and the scoreboard at
the end settles it.

Rules for the screen, so that nobody has to ask whose number they are looking at:

- **Blue is Vertica, orange is ClickHouse**, in every chart and every caption. Dark shades are plain
  SQL, full shades are bitmaps, the light blue is Vertica with its functions fenced.
- **One number at a time.** When the narrator says a number, that bar and its label are the only
  thing highlighted; the engine's name stays next to it.
- **Every test is introduced by its question** (the caption at the top of the chart panel) and
  closed by its verdict (the label at the right of the panel: "Vertica 6.7× faster").
- Every number comes from `blog/BLOG.md`, which takes it from a recorded run; the charts are the
  SVG files of `blog/charts/` (regenerate with `bench/charts.py`); the live part is
  `scripts/demo.sh --pause`.

| # | Scene | Minutes | On screen | The beat |
|---|---|---|---|---|
| 1 | The claim | 0.75 | Black screen, the sentence "We can do that too." typed out; then the title; then "299 recorded runs" | The hook: a sentence everybody says and nobody checks. We checked |
| 2 | The question that hurts | 0.75 | A marketing screen with five filters and a spinner; captions "Vertica, plain SQL: 666 ms" then "32 users: 3.6 s" | The problem, with its first two numbers |
| 3 | The old trick | 1.25 | `bitmap_idea.svg`, animated row by row: AND, AND NOT, count the ones | What a bitmap database is |
| 4 | The specialist | 0.75 | A second box appears next to the warehouse: copy, pipeline, security, operations; then the two-part claim as text | Why people buy a second system; the claim, stated so that it can fail |
| 5 | Building it inside Vertica | 2.25 | `how_it_works.svg`, boxes appearing in order; a card "24 functions in five groups, four programs": build the sets (`bm_build`, `bm_union` and their aggregate forms); ask questions (`bm_count`, `bm_ids`, `bm_ids_text`, `bm_facets`, `bm_eval`); combine stored sets (`bm_and`, `bm_or`, `bm_xor`, `bm_andnot`, `bm_cardinality`, `bm_and_cardinality`, `bm_contains`, `bm_to_ids`, `bm_pair_count`); an audience as a filter (`bm_pin`, `bm_member`, `bm_unpin`); housekeeping (`bm_empty`, `bm_info`, `bm_version`); programs `snapshot.sh`, `live_index.sh`, `bmq`, `demo.sh`. No syntax on screen. Then the words "fenced" and "unfenced" with a one-line definition each | What was built, why it was quick (Vertica is extensible: a compiled function becomes part of the engine for every user), and the two ways it runs |
| 6 | Live demo | 3 | `scripts/demo.sh --pause` (1 M people): build, validate, publish; the question in plain SQL and through the sets, same answer; variants; facets; IDs; 1 % refresh; rollback | It is real: same answer, a fraction of the time |
| 7 | The rules | 0.75 | Rule cards: one machine; one engine at a time; 20 CPUs and 56 GiB each; same rows; every answer checked; the clock stops at the last byte | Why the loser would accept the result |
| 8 | Test one: Vertica against its own SQL | 1 | `latency_1_client.svg`, then `latency_32_clients.svg`; the first panel highlighted | 53 times and 80 times faster; the device query stays plain SQL |
| 9 | Test two: the specialist | 1.75 | `one_question.svg`, bars revealed from the top: 666, 199, 42, then 31 and 13; then the 32-user panel; then `engines_32_clients.svg` | The warning (ClickHouse's SQL is quick), then the first surprise: Vertica's bitmaps beat ClickHouse's bitmaps, and the lead grows with the crowd |
| 10 | The fourteen-second mystery | 0.75 | Before / after: "14.4 s" becomes "3.5 s"; one `CREATE PROJECTION` line | The insight: it was a projection, not code |
| 11 | The case of the slow list | 1.5 | "ClickHouse 38 ms, Vertica 96 ms" in red frame; a timeline of the 96 ms split into 19 and 77; then `id_lists_1_client.svg` | The test that was lost first, investigated, and won |
| 12 | The index that maintains itself | 1.25 | The `CREATE PROJECTION` statement; a terminal: INSERT, COMMIT, count; then `fresh_data.svg` | The second surprise: no build job. ClickHouse takes the append and the build; Vertica answers faster meanwhile |
| 13 | Ten times the data | 0.75 | `scale_100m.svg` | 100 million people: 59 ms against 10 s; 29 minutes become 10 seconds |
| 14 | The verdict | 1.25 | `scoreboard.svg`, group by group; then the three closing sentences as text | 18 of 23; what ClickHouse won; one platform, and the faster one |
| 15 | Check it yourself | 0.5 | Repository link, the two commands, licence; then the disclaimer card (the text at the end of this file), held for about 10 seconds | Nobody has to take our word for it |

## Narration

Spoken text, about 140 words per minute. Every number is the one of `blog/BLOG.md`, and every
number is said together with the engine that produced it.

**1. The claim (0:45).** *(Black screen; the sentence "We can do that too." is typed out. Then the
title. Then "299 recorded runs".)* Every database vendor says the same sentence. "We can do that
too." Graphs, vectors, bitmaps: one platform for everything. It is easy to say, and almost nobody
checks it. We checked. This is the story of one such claim, tested until there was nothing left to
argue about: that Vertica, an analytical database with a wide range of capabilities, also does the
work of a bitmap database, and does it faster than ClickHouse, the engine famous for raw speed,
with its own built-in bitmap functions. Two hundred and ninety-nine benchmark runs, every one
recorded, the failed ones included. More than once the evidence turned against us. Each time we
looked for the cause, and each cause turned out to be worth knowing.

**2. The question that hurts (0:45).** *(A marketing screen with five filters and a spinner; the
two captions appear one after the other.)* It starts with a marketer and one question. People in
the country, aged 25 to 54, who gave consent, whose account is active, and who like sports or finance.
How many? She changes a filter and asks again. And again. Behind her screen there are ten million
people and two hundred million rows of interests, and every click is a new query that joins and
counts them. Vertica is good at this. With projections tuned by its own Database Designer, plain
SQL answers in 666 milliseconds. That is fine for one person. Now give the same screen to
thirty-two analysts at once. The same answer takes three and a half seconds. Nobody explores data
at three and a half seconds a click.

**3. The old trick (1:15).** *(Figure: `charts/bitmap_idea.svg`, animated row by row.)* There is an
old trick for this, and it is beautifully simple. Give every person a number. For every condition
keep one row of bits, one bit per person: a one if the person is in, a zero if not. "Lives in
the country" is one row. "Likes sports" is another. Now "in the country and likes sports" is a
bitwise AND of two rows. "But not finance" is an AND NOT with a third. The answer to "how many" is the number of
ones, and the list of people is the positions of the ones. No join, no sort, no distinct: a person
is one bit, however many rows they have in the tables. Real sets are sparse, so they are
compressed. The Roaring format cuts the ID space into blocks of 65,536 and stores each block in
the smallest of three forms. A database that works this way is a bitmap database.

**4. The specialist (0:45).** *(A second box appears next to the warehouse; then the claim in two
lines.)* This is why companies buy a second system. Next to the warehouse they install an engine
with bitmap functions built in. ClickHouse is the obvious choice: fast, popular, and its bitmaps
are part of the product. The price is not the licence. It is a second copy of the data, a pipeline
to keep that copy in step, a second security model, and a second thing to operate at night. So here
is the claim, stated so that it can fail. One: Vertica can do this job itself, inside the database
you already run. Two: it will not be the slower choice. If the specialist wins on speed, the second
system is justified, and we will say so.

**5. Building it inside Vertica (2:15).** *(Figure: `charts/how_it_works.svg`, boxes appearing in
order; then a card "24 functions in five groups, four programs", each line lighting up as it is
named; then the two words with their definitions.)* Here is what we built, and it is smaller than
you might think. Vertica can be extended. You write a function in C++, compile it into a library,
and load it with one statement. From that moment the function is part of the engine. It is called
from SQL like COUNT or SUM. It runs in parallel inside the query. And every user who is granted it
can use it, from any tool, with nothing to install on their side. Vertica calls this a UDx, a
user-defined extension, and it is the reason this project took days and not months. Storage,
parallel execution, security and transactions were already there. We only had to add the set
arithmetic.

So we added twenty-four functions, in five small groups. Functions that build the sets: each
condition becomes a compressed Roaring set, stored as ordinary rows in an ordinary Vertica table.
Functions that ask questions: one counts an audience, one lists its people, one breaks it down by
every topic, each in a single pass over the sets. Functions that combine two stored sets directly.
Functions that turn an audience into a filter on any other table. And a few for housekeeping.
Around them, four programs. One builds the index, checks it and publishes it. One sets up an index
that Vertica maintains by itself. One asks questions from the command line. And one is a
five-minute demo, which you will see in a moment.

Two words you will hear again. Fenced: the functions run in a separate process, so a fault in the
extension can never touch the server. Unfenced: they run inside the server, the way ClickHouse
runs its own built-in functions. We measured both, and we always say which one we mean. And
because the sets are data inside Vertica, they get what Vertica gives all data. Every set is
counted again from its source, and only then one transaction publishes the whole index. Readers
never see a half-built index, and going back is one statement.

**6. Live demo (3:00).** *(Terminal: `scripts/demo.sh --pause`.)* Narrate each step as it runs:
one million people generated; the sets built, validated and published; the marketer's question in
plain SQL and through the sets, the same answer; four variations of the question, each as fast as
the first; the audience split by topic in one pass; the first IDs; then one percent of the people
change, the batch is applied, validated and published while the old index stays readable; and
finally a rollback, which is nothing more than publishing the previous index again.

**7. The rules (0:45).** *(Rule cards, one at a time.)* A benchmark is worth something only if the
loser would accept it. So the rules were fixed before the first run. One machine. One engine
running at a time. Each engine limited to the same twenty CPUs and the same 56 gigabytes of memory.
The same rows in both, exported from one and loaded into the other. Every answer of every execution
compared with plain SQL: one difference, and the run is invalid. Vertica's own SQL gets its best
chance, tuned by hand and by the Database Designer, and we take the faster of the two. And both
engines are timed the same way: the clock stops when the last byte of the answer has arrived.

**8. Test one: Vertica against its own SQL (1:00).** *(Charts: `charts/latency_1_client.svg`, then
`charts/latency_32_clients.svg`.)* Test one. Before it meets the specialist, Vertica has to beat
itself. The marketer's count: 666 milliseconds in Vertica's tuned plain SQL. Through the bitmap
sets, in the same Vertica: 13 milliseconds. Fifty-three times faster, and the answer is the same
number. With thirty-two analysts at once: plain SQL, three and a half seconds. The bitmap database,
44 milliseconds. Eighty times faster. The other questions follow: who was active each day, the
audience split by five hundred topics, the list of people, between nine and twenty-eight times
faster for one user. One question goes the other way, and it should. A short list of devices,
which a sorted projection already isolates: plain SQL answers in 6 milliseconds, the bitmaps in 8.
The sets are for set questions; they do not replace SQL. Verdict of test one: the bitmap database
is real. But that was the easy opponent.

**9. Test two: the specialist (1:45).** *(Chart: `charts/one_question.svg`, bars revealed from the
top; then the second panel; then `charts/engines_32_clients.svg`.)* Test two. ClickHouse, on the
same machine, with the same data and the same limits. And the first number is a warning.
ClickHouse's plain SQL, with no bitmap at all, answers the marketer's count in 199 milliseconds.
Vertica's plain SQL needed 666. The specialist is three times faster before it has even used its
special weapon. Then it does. ClickHouse's bitmap functions: 42 milliseconds. And now the number
that decides the claim. Vertica's bitmap database, same question, same data: 13 milliseconds.
Three times faster than the specialist, at the specialist's own game. Even fenced, in its safe
mode, Vertica answers in 31. We did not expect that. So we raised the pressure: thirty-two users
at once. ClickHouse's bitmaps: 297 milliseconds. Vertica's: 44. Almost seven times faster. The
lead grows with the crowd, and the reason is in the design. Vertica's function walks through the
sets of one question in a single pass, on a single thread, and leaves the other cores to the other
thirty-one users. Across the six questions, with thirty-two users, Vertica is ahead on five and
level on the sixth. For a single user it is ahead on five, and ClickHouse takes one: the split by
five hundred topics, 146 milliseconds against Vertica's 157.

**10. The fourteen-second mystery (0:45).** *(Before and after: "14.4 s" becomes "3.5 s"; one
CREATE PROJECTION line.)* It was not always like that. In an early run, that topic breakdown for
thirty-two users took Vertica's bitmaps fourteen seconds. Something was badly wrong, and it was not
the code. The sets were stored sorted by condition. To evaluate a question block by block, Vertica
had to sort them again for every query, and thirty-two sorts fought for memory. The fix was one
statement: a second projection of the same table, sorted by block. Fourteen seconds became three
and a half. Not one function changed. That is the insight we would give anyone who builds on
Vertica: before you write code, look at the projection.

**11. The case of the slow list (1:30).** *(The two first numbers in a frame; a timeline of the 96
milliseconds; then `charts/id_lists_1_client.svg`.)* Then came the test we lost. Sometimes the
marketer does not want a number. She wants the people: 530,315 IDs. The first measurement said
ClickHouse delivers that list in 38 milliseconds, and Vertica in 96. We could have left it out.
We took it apart instead. Producing the list inside Vertica takes 19 milliseconds. So where did
the other seventy-seven go? On the road: into half a million separate rows, and into a
command-line client that formats every one of them. So we did two things. We timed both engines
the same way, at the last byte on the wire. And we let Vertica's function hand over each ID
already formatted as text. The result: Vertica 37 milliseconds, ClickHouse 40. With thirty-two
users the two are level. And most lists never travel at all. Counted inside the database: Vertica
19 milliseconds, ClickHouse 33. Used as a filter on a table of ten million rows: Vertica 36,
ClickHouse 61. The average age of the audience, computed from sets alone, with no join: Vertica
29, ClickHouse 47. Seven uses of the list for one user, and Vertica is ahead in all seven.

**12. The index that maintains itself (1:15).** *(The CREATE PROJECTION statement; a terminal with
INSERT, COMMIT and a count; then `charts/fresh_data.svg`.)* An index is only as good as its
freshness, and this is where we expected the general-purpose database to pay. It did something we
had not planned for. In Vertica the sets can be a live aggregate projection: one CREATE PROJECTION
statement on the table of tags, calling the same functions. From that moment there is no build
job. Every load updates the sets inside its own transaction. We tested it under fire: thirty-two
users querying, and two million new rows arriving. Vertica took them in in 3.9 seconds. The sets
were exact the moment the load committed. No query failed, and none returned a wrong number.
ClickHouse keeps live sets too, and its append was one second quicker: 2.9 seconds. It also builds
all the sets from scratch faster: about three seconds, against Vertica's eight. Those two go to
ClickHouse. But while that load was running, the marketer's count came back from Vertica in 309
milliseconds, and from ClickHouse in 393.

**13. Ten times the data (0:45).** *(Chart: `charts/scale_100m.svg`.)* Does it hold when the data
grows? One hundred million people, two billion rows of interests. Vertica's plain SQL needs ten
seconds for the marketer's count. Vertica's bitmap database: 59 milliseconds. The list of 5.3
million people: 38 seconds in plain SQL, under three tenths of a second from the sets. The overlap
ranking, which took plain SQL twenty-nine minutes, takes ten seconds. And the split by five
hundred topics, which reads the whole index at this size, takes ten seconds where plain SQL takes
eighteen.

**14. The verdict (1:15).** *(Chart: `charts/scoreboard.svg`, group by group; then the closing
sentences as text.)* So, the scoreboard. Twenty-three tests, side by side. Vertica is faster in
eighteen. ClickHouse is faster in four: building the sets, the live append, and the topic
breakdown in two situations. One is level. On the nineteen audience questions alone, the job the
specialist is bought for, Vertica is faster in seventeen. We set out to test a sentence that every
vendor says: one platform can do it all. For this job the sentence can now be replaced by
measurements. Vertica is an analytical database with a wide range of capabilities, and
high-performance bitmaps are one of them. It answers audience questions up to 6.7 times faster
than ClickHouse's own bitmap functions. One system to load, to secure and to operate. And it is
the faster one.

**15. Check it yourself (0:30).** *(Repository link, the two commands, the licence; then the
disclaimer card.)* Do not take our word for it. That was the point of the whole exercise. The
extension, the scripts, the benchmark and the raw files of every run we cited are in the
repository. One script repeats the benchmark on your own machine, and a five-minute demo builds an
index, queries it and rolls it back. Graph analytics and vector search already have companion
extensions built the same way; this one adds the bitmap database. If your users ask set questions,
you already own the engine. It is the Vertica that runs the rest of your warehouse.

Recording notes: run the demo on a warm database (one run before recording); the terminal font
large enough for 1080p; charts full screen, one at a time, with the panel that is being spoken
about highlighted; engine names always visible next to the numbers; the repository link and
licence on the closing frame, followed by the disclaimer card.

## Disclaimer

The last card of the video, held long enough to read (about 10 seconds) and repeated in the video
description. It is shown, not spoken.

This work is a demonstration. It is not an official product or functionality offered by Rocket
Software, and it is provided "as is", without warranties of any kind. All brands and product names,
including Vertica and ClickHouse, are mentioned for reference only and belong to their respective
owners.
