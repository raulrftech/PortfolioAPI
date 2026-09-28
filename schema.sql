-- DDL = Data Definition Language
--      The subset of SQL that defines or changes the structure of the data base
--      Shaping the containers, not touching any rows
-- The other half is DML (Data Manipulation Language) - Insert, Update, Delete, Select
--      works with the actual data inside those containers once they exist
/*
CREATE TABLE categories (
    id      SERIAL PRIMARY KEY,
    -- Serial atuo genertes 1,2,3 for every new row; Primary Key marks it as that row's unique identifier. One column, two jobs
    name    TEXT NOT NULL UNIQUE
    -- TEXT is Postgre's general-purpose string type; Not Null means the insert fails if this is empty
    -- Unique tacked onto categories.name - no two categories can share the same name
);
*/

-- categories had to be created before products, because products.category_id references it - Postgres needs the table you're pointing at to already exit
-- Your holdings table refrences both accounts and assets, so those two need to be created first, holdings last
/*
CREATE TABLE products (
    id              SERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    category_id     INTEGER NOT NULL REFERENCES categories(id),
    -- the foreign key. Integer because it's storing a numeric id. References means that value has to already exist over in categories
    --  Not Null means every product must belong to some category - no orphans
    price           NUMERIC(10, 2) NOT NULL CHECK (price > 0),
    -- Numeric(10, 2): update to 10 total digits, 2 after the decimal (never FLOAT for money - same reason as before)
    -- CHECK (price > 0) rejects a zero or negative price outright
    created_at      TIMESTAMP DEFAULT NOW()
    -- auto-fills the current timestamp if you don't specify one on insert
);
*/

CREATE TABLE accounts (
    id                  SERIAL PRIMARY KEY,
    name                TEXT NOT NULL,
    -- what does one row in accounts acutally need to know about itself, beyond an id and a name
    account_type        TEXT NOT NULL CHECK (account_type IN ('brokerage', 'roth_ira', '401k')),
    -- A portfolio-tracking app almost always has more than one kind of account (brokerage, Roth IRA, 401k) and
    -- your holdings/transactions logic doesn't care which but a human looking at their dashboard does
    -- IN () means "must be one of these exact values" - same CHECK mechanishm, now doing set-membership instead of a numeric comparison
    created_at          TIMESTAMP DEFAULT NOW()
    -- what is left out on purpose: a balance column
    --      tempting because real accounts have cash but check what the capstone actually requires: post /transactions validates "cant sell more than you hold" (a holdings-quantity check)
    --      and GET /accounts/id/summary aggregates portfolio value form holdings * asset price which are both computed form other tables
    --      Nothing in scoperight now needs a stored cash balance and its a cheap ALTER TABLE later if a "cant buy more than you can afford" rule ever gets added
    -- No user)id either - there's no User/auth entity anywhere so theres nothing for it to reference yet
);

CREATE TABLE assets (
    id                  SERIAL PRIMARY KEY,
    ticker_symbol       TEXT NOT NULL UNIQUE,
    category            TEXT NOT NULL CHECK (category IN ('tech', 'finance', 'home_appliance', 'commerce')),
    asset_price         NUMERIC(9, 3) NOT NULL CHECK (asset_price > 0)
);

CREATE TABLE holdings (
    -- holdings isnt storing or assets themselves, its recording the relationship between an account and an asset: which asset a given account currenlty owns and how much
    -- One accoutn ca hold many different assets and asset can be held by many different accounts so yu. need a table sitting between the two, with a foreign key pointing at each side
    -- plus at least one column of its own to say how much
    id              SERIAL PRIMARY KEY,
    -- auto-increment plus unique identifier
    account_id      INTEGER NOT NULL REFERENCES accounts(id),
    -- first foreign key, this holding has to belong to a real row in accounts, NOT NULL means it cannot float unattached to any account
    asset_id        INTEGER NOT NULL REFERENCES assets(id),
    -- second foreign key, same logic, pointing at assets instead. A holding always names which account owns which asset - thats the whole reason this table exists
    quantity        NUMERIC(12, 4) NOT NULL CHECK (quantity >= 0),
    -- fractional shares are real (many brokerages let you buy a $50 of a stock and get 0.2481 shares of it) so a whole-number type would silently break the moment that happens
    -- (12, 4) gives four decimal places of room - plent for fractional shares - and 8 digits before the decimal for the whole number part
    -- CHECK (etc) blocks a negative holding, since holding -3 chares isnt a real state
    -- Notice its >= 0, like price was - a holding legitemately can sit at exactly 0 after a full sell off whereas price of 0 never made sense
    UNIQUE (account_id, asset_id)
    -- same shape as UNIQUE (authorID, title). It stops account 5 from ever having two separate rows both pointing at a particular asset.
    -- if account 5 already holds a particular asset and buys more, the right move is updating that existing row's quantity and not inserting a second row for the same pair
);
-- One ordering note, accounts and assets both have to already exit before this CREATE TABLE runs since holdings references both


-- SQL Part 2 - Joins, Aggregation, trnsactions/ACID and Index
-- Why joins exist:
    -- the whole point of pslitting your data into account, assets and holdings instead of one giant table was normalization - no duplicated data, everything with one clear home
    --      But that means the info you actually want ie whihc account owns which asset and how much is now spread across three tables
    -- A JOIN is how you pull related rows abck together across tables ina single query
-- Worked example, give each holding along with the account it belongs to

SELECT accounts.name, holdings.quantity, assets.ticker_symbol
FROM holdings
JOIN accounts ON holdings.account_id = accounts.id
JOIN assets on holdings.asset_id = assets.id;
-- A semicolon marks the end of one complete SQL statement, everything from a command keyword up to its semicolon is treated as one single,
--      self contained instruction sent to Postgres
-- A file or a single run can contain many statements back to back, each close siwth its own sc and they get executed one at a time, completely independent
-- That independence is they key part: whatever sits between one sc and the next has to work as a complete statement on its own
--      completely independently of each other
-- FROM holdings - start from this table
-- JOIN accounts - pull in this table too
-- ON holdings.account_id = accounts.id -> the matching rule; line up a holdings row with the accounts row where the foreign key actually points
                                        -- This is ecact relationship your REFERENCES accounts(id) constraint already declared - JOIN is just using that relationship to combine the data
-- SELECT holdings.quantity, accounts.name - table name prefixes here are not optional, theyre how you disambiguate columns that exist in btoh tables (both have an id, for instance)
-- This specific kind - where a row only shows up if it matches on both sides - is called an INNER JOIn; plain JOIN defaults to that
-- add assets into the same query so the result also shows the ticker symbol, not just the account name
-- The SELECT list and the JOIN clauses do two different jobs
--      Joins only control which tables are available to pull from, they dont put anything into the output by themselves
--      SELECT list is the one and only place that decides what actually shows up in the result, and its a single csv list that all sits together right after the word SELECT, before FROM
--      It doesnt matter how mnay tables get joined below it - every column you want in output, from any of those tables, goes into that same one list at the top, not scattered near whichever join it came from

-- Aggregation - GROUP BY, the aggregate functions (COUNT, SUM, AVG, MIN, MAX) and HAVING
--      This is a step up from the JOIN work: instead of extending a pattern you already had, youre picking up three new pieces at once
-- The Core Idea:
--      an aggregate function collapses multiple rows down into a single calculated value
-- Count(*) counts rows, SUM(column) adds a numeric column up, AVG averages it, MIN/MAX grab the extremes
--      On their own, with no GROUP BY, an aggregate collapses your entire result set into one row - SELECT COUNT(*) FROM holdings give you one number for the whole table
-- GROUP BY changes that
--      It buckets your rows into groups that share the same value in a given column
--      Then the aggregate functions runs separately per group instead of over everything at once
--      So instead of one number for the whole table, you get one number per account or one number per ticker - whatever you grouped by
-- Hers a full worked ecample - how many holdings each account has
/*
SELECT accounts.name, COUNT(*)
FROM holdings
JOIN accounts ON holdings.account_id = accounts.id
GROUP BY accounts.name
*/
-- Walking through it:
--      the join has same mechanics as before, just getting accounts.name reachable alongside holdings rows
--      GROUP BY accounts.name tells Postgres collapse all the rows into one bucket per distinct account name
--      Once thats done, COUNT(*) isnt counting the whole table anymore, its counting how many rows landed in each individual bucket
--      There;s a hard rule that goes with this: every plain (non-aggregated) column in your SELECT list has to also appear in the GROUP BY
--          Postgres will reject the query otherwise because it woudlnt know whcih single value to show for a column that wasnt grouped on
-- The other new piece is HAVING, which may be easy to confuse with WHERE but does a different job
--      WHERE filters individual rows before any grouping or aggregating happens
--      HAVING filters the groups themselves, after aggregationg, based on the aggregated value - something WHERE cant do, since the aggregate value doesnt exist yet at the point WHERE runs
-- Extending the same example, to only see accounts with more than 2 holdings
/*
SELECT accounts.name, COUNT(*)
FROM holdings
JOIN accounts on holdings.account_id = accounts.id
GROUP BY accounts.name
HAVING COUNT(*) > 2;
*/
-- My independent task
--      Using holdings and assets, write a query that shows, for each ticker symbol, the total quantiy held across all accounts
--      Same pattern as above, just a different aggregate function and a different pair of tables
--      Write it out and explain each line when its written
INSERT INTO accounts (name, account_type)
VALUES ('Brokerage 1', 'brokerage');
INSERT INTO accounts (name, account_type)
VALUES ('401k2 2', '401k');
INSERT INTO accounts (name, account_type)
VALUES ('Roth 2', 'roth_ira');

INSERT INTO assets (ticker_symbol, category, asset_price)
VALUES ('MSFT', 'tech', 402.750);
