# pg_suggest_rewrite

*Warning*: The code is AI generated, review any output carefully

This function generates SQL to rewrite column order of a table

Some of this code is based on https://github.com/rogerwelin/pg_column_tetris

## Usage

For optimized order (PKs, FKs, Then optimal order)
```sql
select suggest_rewrite('mytable');
```
For custom order (missing columns will be added last in original order)
```sql
select suggest_rewrite('mytable',ARRAY['id',...]);
```
## License
MIT