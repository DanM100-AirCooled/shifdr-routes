-- Removes the drives tests/fixture.sql made (their roster rows go with them).
delete from public.events where title like '[test] %' returning code, title;
