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
            As long as the interface between client and server (the API) stays the same, either side can change independently without the other knowing or caring
                You could swap out Postgres for something else entirely or completely redesign the frontend and as long as the contract in between does not change, nothing breaks on the other side
            That stable boundary is what "API contract design" is actually about
        One server, many clients
            A real compnay might have a web app, an iOS app, and an Android app, built by three different teams - but all of them can talk to the same backend
                So the logic for something like "how do you calculate a portfolio's value" gets written once, in one place, isntead of 3 times across 3 codebases that could quietly drift out of sync with each other
        One place to actually enforce the rules
            The server is the only place your rules can be trusted to run, because you cannot rely on a client to enforce anything on itself
    
    When do you actually need more than one server?
        Different, unrelated applivations get different servers. "One server, many clients" was about multiple clients of the same application
            A second, unrelated project you build someday is simply a separate server
        Too much traffic for one machine
            When a single server cant keep up with the request colume, you run several identical copies of the same server behind a load balancer that spreads requests across them "horizontally scaling"
        Splitting one large application into smaller independent pieces (a payments service, a notifications service, etc.) each its own server, usually called microservices
        Reliability - more than one server so if one goes down, another keeps serving

    The request/response cycle
        By defualt, this relationship is client-initiated:
            the server does not reach out to clients on its own, it waits, and only does anything in response to a request arriving
            (WebSockets/server push are the named exception - the server sending data without being asked first - but thats not the default mode, and not what your REST API does)
            Concretely, in your own proj, you open Postman, point it at localhost:8080/acccounts, hit send
                Request out, response back - that whole round trip is the cycle
                Postman is just standing in as "a client" for now; a real frontend would make that exact same kind of request, just from a browser or app instead of a testing tool
        A request has four paets, a method (GET, POST, etc), a URL/path, headers (metadata, like an auth token), and sometimes a body (the actual data, e.g. JSON you're sending)
        A response mirrors that: a status code, headers and a body. Thats exactly what you'll see in Postman once there's a server to hit - a method dropdown and URL bar on one side, status code and response body on the other
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
            Because the server doesnt hardcode anything about is this a browser or is this mobile, you can add a brand new kind of client, a smartwatch app, a CLI tool, another partner 2 years from now, without ever touching the server
            If the server did need to special-case each client type, every new client would mean a server change
            This is the actual mechanism behind the answer to the next, one server, many clients only works because the server treats all of them identically
        If you have a web client and a mobile client that both need the same data, do you biild one server that both talk to, or 2 separate servers? Why?
            One server that both talk to and this is so that there isnt more than one codebase that can drift out of sync with the other
        When a request hits your server, what actually tells it which account or user is making that request?
            i would assume that the identifying information about the account or user making the request is included along with the request
            Concretely, that usually means a token or credential attached to the request itself, most commonly an Authorization header carrying soemthing like a bearer token or a session cookie
            The key idea is: identity travels explicitly with the request, always, never guessed from context
*/

/*
    REST

    What it actually is:
        not a protocol or a strict standard, just a set of conventions for designing APIs on top of the request/response cycle, so APIs end up predictable instead of everyone inventing their own scheme
    The Core Ideas:
        Resources are nouns, represented by URLS
            /accoounts, /accounts/5, /accounts/5/holdings, not vers baked into the URL like /getAccountById
        Operations are HTTPS methods, not URL text
            GET reads, POST creates, PUT/PATCH updates, DELETE removes
            The verb lives in the method, never the path
        Status codes communicate outcome, consistently
            200 OK, 201 Created, 400 Bad Request, 404 Not Found, 500 Internal Server Error - standard meanings, so a client can interpret the result without per-endpoint documentation
    Real-World Context - this is literally your API
        GET /accounts/5, POST /accounts, POST /transactions, GET /accounts/id/summary - all allready siting on your captstone core build list
            REST is the convention youll be following when you build those for real
        Edge Cases Worth Knowing Now
            Not every operaiton maps cleanly to a noun - something like "activate this account" doesnt fit neatly into get, post, put, delete on a resource, and real APIs handle this in genuinely different, debated ways
            Picking the wrong status code is a common real mistake - returning 200 on an error breaks a client's error handling, since the response is now lying about what happened
            Nested vs flat Urls (/accounts/5/holdings vs /holdings?accountId=5) is a real design decision you'll face defining your own API contract, not trivia

/*
-- Exercise 1 - Propose the URL, the HTTP method, and the status code
    -- A client wants to fetch the details of a single account with ID 5. What is the URL, what method do you use, and what status code do you expect back on a sueccess
        -- the url would be /accounts/5. The method Id use is GET since it reads and the status code would be 200 if the server works and 500 if not
    -- Also, what status code would you expect if account 5 does not exist
        -- if the account does not exist, then the status code would be 404
    -- One thing to refine - framing it as 200 if the server works and 500 if not, which puts 500 in the came category as 404, like its a 3rd outcome youre deliberately coding for, its not
    -- Here's the actual split
        -- 2xx (200, 201...) - success. You design for this
        -- 4xx (400, 404...) - something wrong with the request itself. You design for this too, "no account with that ID" is a completely normal, anticipated case for a GET-by-id endpoint,
            -- which is exactly why 404 is one of the two outcomes listed
        -- 5xx (500...) - something borke on the server while it was trying to handle an otherwise valid request.
            -- You do not design a branch that returns this. It's what happens automatically when your code thorws an exception you did not catch, a null pointer, the database connection dropping, whatever
            -- There's no if statement in your controller that says "return 500", it is the fallback for something you didn't anticipate goes wrong
    -- So for this endpoint, the 2 outcomes you design are 200 (found it) and 404 (not found). 500 isnt a third branch sitting next to those, its what happens if code is buggy or something fails unexpectedly
-- Exercise 2
    -- A client wants to create a new account.
    -- What is the URL, what method do you use and what status code do you expect back on success?
        -- POST /accounts newUserInfo, status code on success is 201 for creation
    -- What status code would you expect if the request is missing a required field (say, the account owner's name)
        -- Status code for invalidity in this case would be 400, insufficient information yields a bad request
-- Exercise 3
    -- A client wants to update just the email address on an existing account with ID 5, not replace the whole account record, just that one field
    -- What URL, what method, and what status code on success
        -- I forget what the the difference between PUT and PATCH is so ill stick with PUT /accounts/5/emailAddress or soemthing of the sort, status code on success would be 200 since nothing is created, just replaced
    -- The URL /accounts/5/emailAddress treats the email like its own resource, same way holdings is but holdings are genuinely separate entities with their own identity, while emailAddress
        -- is just one attribute of the account. The resource being updates is still account itself. The URL stays /accounts/5. Which field you're changing goes in the request body, not the URL
    -- PUT vs PATCH:
        -- PUT = full replacement, the contract is "here is the entire representation of this resource, repalce what you have with exactly this"
            -- If you PUT to /accounts/5 with only {"email": "..."} in the body, a strict implementation treats that as "this is now the whole account" and could wipe out every other field you did not include
        -- PATCH - partial update, built specifically for "change just these fields, leave everything else alone" which is exactly what this exercise asked for
    -- Real World Edge Case worth knowing:
        -- plenty of production APIs are loose about this and use PUT for partial updates anyway but PATCH is the spec-correct, interview-correct answer when the question is specifically "update one field"
-- Exercise 4
    -- A clients wants to delete account 5. What is the URL, what method and status code do you expect on success?
        -- DELETE /accounts/5, status code would be 200 for success, not 201 since nothing is getting created but destroyed, if user tries to access the acc again it would be 404
    -- For DELETE specifically, the spec-precise answer is 204 No Content
        -- A successful DELETE has nothing menaingful to send back - the resource is gone, there is no new state to describe
        -- 204 means exactly that: "this succeeded and there is intentionally no body in this response"
        -- 200 implies a body is coming back which does not really fit a delete
    -- Plenty of real-world APIs just use 200 for deletes anyway (sometimes with a small confirmation message in the body - a legit reason to pick 200 instead) but 2-4 is the interview-expected answer
-- Exercise 5
    -- A client wants a list of all accounts. What is the URL, the method, and the status code on success - including the case where there happen to be 0 accounts in the system?
        -- Since this would be a bad request the status code is 400, the url would be GET /accounts, if there are accounts the status code would be 200
    -- 400 Bad Request means something is wrong with the request itself such as bad syntax, missing required parameter, a malformed body
    -- GET /accounts with nothing else attached is a perfectly well-formed request. Theres nothing wrong with it, so 400 does not apply no matter what the result turns out to be
    -- THe server runs the query succesfully either way, if there happens to be 0 accounts, the honest correct answer to give me all accounts is an empty list, thats a complete, succesfully response, not a failure
    -- Here's the contrast with exercise 1 that matters:
        -- /accounts/5 names one specific resource that either exists or doesnt, hence 404 when it is missing
        -- /accounts names the collection itself, whihc always exists as a queryable endpoint regardless of how many items currently match
        -- So the rule is: GET /accounts -> 200 with body [] whether there are 0 or >1 accounts
            -- The account of results changes what is in the boyd but never changes the status code
-- Bonus Further-Depth Exercises
    -- Scenario 1 - Buying Shares
        -- A client wants to buy 10 shares of ticker AAPL for account 5. Behind the scenes this needs to: confirm the asset exits, confirm account 5 has enough cash to cover the purchase, create a transaction record, and update
            -- or create the corresponding holding. Design the endpoing for this action - URL, method, what goes in the request body, 
            -- then walk through every outcome you can think of: success case, at least 2 distinct fialure cases, with a status code and reasoning for each
            -- In order to access assets it would be GET /assets, to confirm the account has enough it would be GET /accounts/5 in order to check the balance, the transaction record would be made upon success whihc is 200
            -- the update or create would be PUT /accounts/5/holdings/assetID, using PUT here since you had said that PUT is used in companies to either update or create
            -- 2 distinct failure cases would be the account not existing so 404 for that, no asset of AAPL found within /holdings so 404 on that too, I think insufficient cas would be 400 since he/she needs a certain amount for 10 shares
        -- The Core Issue:
            -- the prompt asked you to design the endpoint (singular) for buy 10 shares of AAPL for acc 5. WHat was described is a sequence of 3 separate client-facing calls,
                -- which means the client ends up responsible for checking the asset exists, checking the balance, and deciding whether to proceed. That's exactly what Client-Server taught you to avoid:
                    -- business logic belongs on the server, not the client.
                    -- If the client has to orchestrate "check the balance, then decide whether to call the next endpoint", you've pushed the actual buy-or-reject decision onto whoever's calling your API
                        -- and nothing stops a buggy or malicious client from skipping the balance check and calling the PUT directly
        -- The Fix:
            -- one endpoint, one request from the client's pov. That's POST /transactions. The client sends what it wants to happen; the server does all the checking and all the internal updates (including touching the holdings table) as part of handling that single request:
                -- POST /transactions {"accountId" : 5, "ticker" : "AAPL", "quantity": 10, "type": "BUY"}
                -- Checking the asset exists, checking the balance, creating the trans record, updating holdings, all of this still happens. It just happens inside the server's handling of this one request, not as separate calls the client sequences itself
        -- Status Codes, Against That Corrected Design:
            -- Success, said 200. Think back to exercise 2: a transaction record is a brand new resource being created here, same as the new account was. This should be 201 Created, not 200
                -- Good question to ask yourself going forward: does this bring a new resource into existence, not just did it succeed
            -- Account doesnt exist: 404 was correct
            -- Asset doesnt exist, 404 in principle but what the phrasing, saying no asset of AAPL found within /holdings checks the wrong thins.
                -- Whether the account already holds AAPL is irrelevant to whether AAPL can be bought, not holding it yet is the completely normal case for a first-time purchase, not an error
                -- The real check is does AAPL exist as a tradable asset in the system at all, a lookup against the assets table, not the accounts holdings
                -- Insufficient funds, you said 400 and thats not wrong. Its in the right family. But here's a more precise code, 422 Unprocessable Entity, which a lot of real APIs use
                    -- specifically for this request is well formed but it violates a businesss rule, exactly what insufficient funds is
                -- Some APIs use 409 Conflic for the same situation (request conflicts with the accounts current state)
                    -- Both are legitamte and APIs genuinely split between them, 400 is the safe generic fallback if you dont want to commit to either