FROM postgres:13
COPY spec/fixtures/schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY spec/fixtures/data.sql /docker-entrypoint-initdb.d/02_data.sql
