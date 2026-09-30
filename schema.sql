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

SELECT assets.ticker_symbol, SUM(holdings.quantity)
FROM holdings
JOIN assets ON holdings.asset_id = assets.id
GROUP BY assets.ticker_symbol;
-- An INNER JOIN (JOIN by default) only returns rows that have a match on both sides, so an asset or acc with 0 mathcing holdings rows doesnt show up in the result at all, let alone get grouped
SELECT * FROM accounts; SELECT * FROM assets; SELECT * FROM holdings;
INSERT INTO holdings (account_id, asset_id, quantity)
VALUES (2, 5, 15);
INSERT INTO holdings (account_id, asset_id, quantity)
VALUES (3, 1, 20);
INSERT INTO holdings (account_id, asset_id, quantity)
VALUES (4, 5, 25);
-- Two separate things you can restrict and you can combine then
-- Which columns come back - swap * for the column name you actually want, comma separated if you want more than one
    -- SELECT ticker_symbol FROM assets;
-- Which rows come back - add a WHERE clause. Works regardless of which columns you selected and it filters based on a condition
    -- SELECT * FROM assets WHERE ticker_symbol = 'MSFT';
    -- Same quoting rule as INSERT applies here: ticker_symbol is text, so the value needs single quotes.
    -- Filtering on a numeric column like asset_price wouldn't:
    -- SELECT * FROM assets WHERE asset_price > 100;
-- And you can stack both - specific columns, rows, in one query
    -- SELECT ticker_symbol, asset_price FROM assets WHERE category = 'tech';
    -- With price: SELECT ticker_symbol, asset_price FROM assets WHERE category = 'tech' AND asset_price > 100




-- Going to restart my progress since it was quite rushed before this push
/*
    What a client and server actually are
        You split an application into two separate programs that talk to each other over a network
            The server is a long running program holding the real data and the real logic - in your case, your Spring Boot app plus the Postgres database behind it. It just sits there, waiting
            The client is whatever's making requests to it. Right now thats Postman, later it could be a real web frontend, mobile app, or someone elses system hitting your API

    Why split it this way at all? A few oncrete reasons, not just "thats how its done":
        Separation of Concerns
            The client's job is presentation
                Showing data, collecting input
            The server's job is the actual business logic and data access
            If you dont separate those, every place that touches the data has to reimplement the rules for touching it correctly
        One server, many clients
            A real compnay might have a web app, an iOS app, and an Android app, built by three different teams - but all of them can talk to the same backend
                So the logic for something like "how do you calculate a portfolio's value" gets written once, in one place, isntead of 3 times across 3 codebases that could quietly drift out of sync with each other
        One place to actually enforce the rules
            The server is the only place your rules can be trusted to run, because you cannot rely on a client to enforce anything on itself

    The request/response cycle
        By defualt, this relationship is client-initiated:
            the server does not reach out to clients on its own, it waits, and only does anything in response to a request arriving
            (WebSockets/server push are the named exception - the server sending data without being asked first - but thats not the default mode, and not what your REST API does)
            Concretely, in your own proj, you open Postman, point it at localhost:8080/acccounts, hit send
                Request out, response back - that whole round trip is the cycle
                Postman is just standing in as "a client" for now; a real frontend would make that exact same kind of request, just from a browser or app instead of a testing tool
    One more piece to sit with:
        The server does not actually know or care, ata deep level, whether a request came from Postman, a browser, a phone or someone else's server entirely -
            it sees "a well-formed request arrived" and processes it the same way no matter where it came from

    Five Questions to Begin:
        Say a web app, mobile app, and a partner's 3rd party integreation all send requests to the same /accounts endpoint on your sever. What does the server actually need to know about which of those three it's talking to?
            Im going to guess on this, its whichever account is trying to be logged into on each of these 3 devices respectively that signifies that the request is being made by that particular device

            The server doesnt actually need to know which of the three it's talking to at all, that distinction is basically invisible to it
            All 3 just show up as an HTTP request to /accounts.
            What it needs is who, which account, and that identity is carried the same way regardless of which of the three sent it
            The web app, mobile app and partner integration could all be acting on behalf of the same account and the server would handle very one of the requests identically
        If your client's form blocks a user from entering a negative quantity, and that check only exists on the client side, how could a negative quantity still end up in your database?
            No idea tbh, as said previously, the business logic enforces the rules because the client is never trusted to enforce the rules

            That form's validation only runs inside the client's own code, a JS check in a browser. Nothing forces anyone to go through the form to reach your server
            Postman does not run your form's JS, it just sends raw HTTP directly
            You could open Postman rn and POST a negative quantity straight to your server, skipping the form entirely. if the server does not recheck that value itself, it goes straight to the database
        Why does it matter, architecturally, that the server does not need to know or care whether a request came froma browser, mobile app or something else?
            No idea, this wasnt really expalined
        If you have a web client and a mobile client that both need the same data, do you biild one server that both talk to, or 2 separate servers? Why?
            One server that both talk to and this is so that there isnt more than one codebase that can drift out of sync with the other
        When a request hits your server, what actually tells it which account or user is making that request?
            i would assume that the identifying information about the account or user making the request is included along with the request
*/
