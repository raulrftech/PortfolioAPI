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