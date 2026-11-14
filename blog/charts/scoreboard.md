| Test | Vertica | ClickHouse | Faster |
|---|---:|---:|---|
| **Audience questions, one user** | | | |
| How many people are in this audience? | **13 ms** | 42 ms | **Vertica, 3.3×** |
| How many distinct web users on each of two days? | **5.8 ms** | 17 ms | **Vertica, 2.9×** |
| Split the audience by all 500 topics | 157 ms | **146 ms** | ClickHouse, 1.1× |
| Rank 499 topics by their overlap with sports | **195 ms** | 230 ms | **Vertica, 1.2×** |
| Send the 530,315 IDs of an audience, one row per ID | **37 ms** | 40 ms | **Vertica, 1.1×** |
| Use that list of IDs inside the database | **19 ms** | 33 ms | **Vertica, 1.8×** |
| Filter a 10 M-row table by the audience | **36 ms** | 61 ms | **Vertica, 1.7×** |
| Total an attribute over the audience (bit slices) | **29 ms** | 47 ms | **Vertica, 1.6×** |
| Save the audience as a set | **31 ms** | 35 ms | **Vertica, 1.1×** |
| List the 19,695 hot devices | **8.0 ms** | 16 ms | **Vertica, 1.9×** |
| **Audience questions, 32 users at once** | | | |
| How many people are in this audience? | **44 ms** | 297 ms | **Vertica, 6.7×** |
| How many distinct web users on each of two days? | **44 ms** | 191 ms | **Vertica, 4.3×** |
| Split the audience by all 500 topics | **896 ms** | 2.27 s | **Vertica, 2.5×** |
| Rank 499 topics by their overlap with sports | **924 ms** | 2.23 s | **Vertica, 2.4×** |
| Send the 530,315 IDs of an audience, one row per ID | 266 ms | 263 ms | level |
| Use that list of IDs inside the database | **59 ms** | 244 ms | **Vertica, 4.2×** |
| Filter a 10 M-row table by the audience | **331 ms** | 545 ms | **Vertica, 1.6×** |
| Total an attribute over the audience (bit slices) | **112 ms** | 335 ms | **Vertica, 3.0×** |
| List the 19,695 hot devices | **36 ms** | 76 ms | **Vertica, 2.1×** |
| **Keeping the sets fresh** | | | |
| Append 2 M rows to live sets under 32 users | 3.9 s | **2.9 s** | ClickHouse, 1.4× |
| Audience count during that load | **309 ms** | 393 ms | **Vertica, 1.3×** |
| 500-topic breakdown during that load | 2.41 s | **1.86 s** | ClickHouse, 1.3× |
| Build all 698 sets from the source tables | 8.3 s | **2.9 s** | ClickHouse, 2.9× |

Vertica faster: 18 of 23; ClickHouse faster: 4; level: 1.
