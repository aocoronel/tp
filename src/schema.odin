package main

TABLE :: ```
CREATE TABLE IF NOT EXISTS directory (
  name  TEXT NOT NULL UNIQUE PRIMARY KEY,
  count INTEGER DEFAULT 0,
  mtime INTEGER NOT NULL
) WITHOUT ROWID;
```

INSERT :: ```
INSERT INTO directory (name, mtime)
VALUES (?, strftime('%s','now'))
ON CONFLICT(name) DO UPDATE SET
  count = count + 1,
  mtime = strftime('%s','now');
```

DELETE :: ```
DELETE FROM directory
WHERE name = ?
```

FIND :: ```
SELECT name, count, mtime
FROM directory
WHERE name LIKE ? || '%' AND name
NOT LIKE ? || '%/%'
ORDER BY
    CASE
        WHEN mtime >= strftime('%s', 'now') - 86400 THEN 0
        ELSE 1
    END ASC,
    count DESC;
```
