-- Removes the vbitmap library, its functions and schema vbitmap. Touches nothing else.
-- Fails (and changes nothing) if objects outside schema vbitmap still depend on the functions.
DROP LIBRARY IF EXISTS vbitmap.vbitmap CASCADE;
DROP SCHEMA IF EXISTS vbitmap;
