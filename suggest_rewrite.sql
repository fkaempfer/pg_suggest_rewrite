CREATE OR REPLACE FUNCTION suggest_rewrite(
    relation_name text,
    column_order text[] DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_oid                 oid;
    v_relname             text;
    v_schema              text;
    v_ddl                 text;
    v_cols                text := '';
    v_select              text := '';
    v_rename_sequences    text := '';
    v_create_sequences    text := '';
    v_restore_sequences   text := '';
    v_locks               text := '';
    v_drop_fks            text := '';
    v_constraints         text := '';
    v_foreign_keys        text := '';
    v_indexes             text := '';
    v_drop_views          text := '';
    v_create_views        text := '';
    v_drop_triggers       text := '';
    v_create_triggers     text := '';
    v_permissions         text := '';
    v_comments            text := '';
    v_view_comments       text := '';
    col                   record;
    affected_table        record;
    constraint_record     record;
    index_record          record;
    view_record            record;
    trigger_record         record;
    permission_record      record;
    sequence_record        record;
    sequence_last_value    bigint;
    sequence_is_called     boolean;
    comment_record         record;
    grantee_name           text;
BEGIN
    v_oid := relation_name::regclass::oid;

    IF column_order IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
              FROM unnest(column_order) AS requested(attname)
              LEFT JOIN pg_attribute a
                ON a.attrelid = v_oid
               AND a.attname = requested.attname
               AND a.attnum > 0
               AND NOT a.attisdropped
             WHERE requested.attname IS NULL
                OR a.attname IS NULL
        ) THEN
            RAISE EXCEPTION 'column_order contains a column that does not exist on %',
                relation_name;
        END IF;

        IF EXISTS (
            SELECT 1
              FROM unnest(column_order) AS requested(attname)
             GROUP BY requested.attname
            HAVING count(*) > 1
        ) THEN
            RAISE EXCEPTION 'column_order contains duplicate columns';
        END IF;
    END IF;

    SELECT n.nspname, c.relname
      INTO v_schema, v_relname
      FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = v_oid;

    IF obj_description(v_oid, 'pg_class') IS NOT NULL THEN
        v_comments := format(
            E'\nCOMMENT ON TABLE %I.%I IS %L;',
            v_schema, v_relname, obj_description(v_oid, 'pg_class')
        );
    END IF;

    FOR comment_record IN
        SELECT a.attname, col_description(v_oid, a.attnum) AS description
          FROM pg_attribute a
         WHERE a.attrelid = v_oid
           AND a.attnum > 0
           AND NOT a.attisdropped
           AND col_description(v_oid, a.attnum) IS NOT NULL
         ORDER BY a.attnum
    LOOP
        v_comments := v_comments || format(
            E'\nCOMMENT ON COLUMN %I.%I.%I IS %L;',
            v_schema, v_relname, comment_record.attname,
            comment_record.description
        );
    END LOOP;

    -- Capture sequences owned by columns of the old table.  The old sequence
    -- is renamed so the replacement can retain its original name.
    FOR sequence_record IN
        SELECT DISTINCT seq.oid, seqn.nspname AS seqschema, seq.relname AS seqname,
               a.attname, a.attidentity,
               format_type(s.seqtypid, NULL) AS seqtype,
               s.seqstart, s.seqincrement, s.seqmin, s.seqmax,
               s.seqcache, s.seqcycle
          FROM pg_depend d
          JOIN pg_class seq
            ON seq.oid = d.objid
           AND seq.relkind = 'S'
          JOIN pg_namespace seqn ON seqn.oid = seq.relnamespace
          JOIN pg_attribute a
            ON a.attrelid = d.refobjid
           AND a.attnum = d.refobjsubid
          JOIN pg_sequence s ON s.seqrelid = seq.oid
         WHERE d.refclassid = 'pg_class'::regclass
           AND d.refobjid = v_oid
           AND d.refobjsubid > 0
           AND d.deptype IN ('a', 'i')
         ORDER BY seqn.nspname, seq.relname
    LOOP
        EXECUTE format(
            'SELECT last_value, is_called FROM %I.%I',
            sequence_record.seqschema, sequence_record.seqname
        ) INTO sequence_last_value, sequence_is_called;

        v_rename_sequences := v_rename_sequences || format(
            E'\nALTER SEQUENCE %I.%I RENAME TO %I;',
            sequence_record.seqschema, sequence_record.seqname,
            sequence_record.seqname || '_old'
        );

        IF sequence_record.attidentity = '' THEN
            v_create_sequences := v_create_sequences || format(
                E'\nCREATE SEQUENCE %I.%I AS %s INCREMENT BY %s MINVALUE %s MAXVALUE %s START WITH %s CACHE %s %s;',
                sequence_record.seqschema, sequence_record.seqname,
                sequence_record.seqtype, sequence_record.seqincrement,
                sequence_record.seqmin, sequence_record.seqmax,
                sequence_record.seqstart, sequence_record.seqcache,
                CASE WHEN sequence_record.seqcycle THEN 'CYCLE' ELSE 'NO CYCLE' END
            );
        END IF;

        IF sequence_record.attidentity = '' THEN
            v_restore_sequences := v_restore_sequences || format(
                E'\nALTER SEQUENCE %I.%I OWNED BY %I.%I.%I;',
                sequence_record.seqschema, sequence_record.seqname,
                v_schema, v_relname, sequence_record.attname
            );
        END IF;
        v_restore_sequences := v_restore_sequences || format(
            E'\nSELECT setval(%L::regclass, %s, %s);',
            format('%I.%I', sequence_record.seqschema, sequence_record.seqname),
            sequence_last_value,
            CASE WHEN sequence_is_called THEN 'true' ELSE 'false' END
        );
    END LOOP;

    FOR col IN
        SELECT ordered.*
          FROM (
            SELECT DISTINCT ON (a.attnum)
                   a.attname, format_type(a.atttypid, a.atttypmod) AS col_type,
                   a.attnotnull, a.attidentity, a.attgenerated,
                   pg_get_expr(ad.adbin, ad.adrelid) AS default_expr,
                   seqn.nspname AS identity_seq_schema,
                   seq.relname AS identity_seq_name,
                   iseq.seqstart AS identity_seq_start,
                   iseq.seqincrement AS identity_seq_increment,
                   iseq.seqmin AS identity_seq_min,
                   iseq.seqmax AS identity_seq_max,
                   iseq.seqcache AS identity_seq_cache,
                   iseq.seqcycle AS identity_seq_cycle,
                   CASE
                       WHEN t.typlen = -1 THEN 5
                       WHEN t.typalign = 'd' THEN 1
                       WHEN t.typalign = 'i' THEN 2
                       WHEN t.typalign = 's' THEN 3
                       WHEN t.typalign = 'c' THEN 4
                       ELSE 5
                   END AS sort_group,
                   CASE WHEN a.attnotnull THEN 0 ELSE 1 END AS sort_notnull,
                   a.attnum
              FROM pg_attribute a
              JOIN pg_type t ON t.oid = a.atttypid
              LEFT JOIN pg_attrdef ad
                ON ad.adrelid = a.attrelid
               AND ad.adnum = a.attnum
              LEFT JOIN pg_depend sd
                ON sd.refobjid = a.attrelid
               AND sd.refobjsubid = a.attnum
               AND sd.refclassid = 'pg_class'::regclass
               AND sd.deptype IN ('a', 'i')
              LEFT JOIN pg_class seq
                ON seq.oid = sd.objid
               AND seq.relkind = 'S'
              LEFT JOIN pg_namespace seqn ON seqn.oid = seq.relnamespace
              LEFT JOIN pg_sequence iseq ON iseq.seqrelid = seq.oid
             WHERE a.attrelid = v_oid
               AND a.attnum > 0
               AND NOT a.attisdropped
             ORDER BY a.attnum, seq.oid NULLS LAST
          ) AS ordered
         ORDER BY
             CASE
                 WHEN column_order IS NOT NULL THEN
                     COALESCE(array_position(column_order, ordered.attname::text), 2147483647)
                 WHEN EXISTS (
                     SELECT 1
                       FROM pg_constraint c
                      WHERE c.conrelid = v_oid
                        AND c.contype = 'p'
                        AND ordered.attnum = ANY (c.conkey)
                 ) THEN 1
                 WHEN EXISTS (
                     SELECT 1
                       FROM pg_constraint c
                      WHERE c.conrelid = v_oid
                        AND c.contype = 'f'
                        AND ordered.attnum = ANY (c.conkey)
                 ) THEN 2
                 ELSE 3
             END,
             CASE WHEN column_order IS NOT NULL THEN ordered.attnum ELSE ordered.sort_group END,
             CASE WHEN column_order IS NOT NULL THEN ordered.attnum ELSE ordered.sort_notnull END,
             ordered.attnum
    LOOP
        IF v_cols <> '' THEN
            v_cols := v_cols || E',\n';
            v_select := v_select || ', ';
        END IF;
        v_cols := v_cols || '    ' || format('%I %s', col.attname, col.col_type);
        IF col.attnotnull THEN
            v_cols := v_cols || ' NOT NULL';
        END IF;
        IF col.attgenerated = 's' THEN
            v_cols := v_cols || format(
                ' GENERATED ALWAYS AS (%s) STORED', col.default_expr
            );
        ELSIF col.attgenerated = 'v' THEN
            v_cols := v_cols || format(
                ' GENERATED ALWAYS AS (%s) VIRTUAL', col.default_expr
            );
        ELSIF col.attidentity <> '' THEN
            v_cols := v_cols || CASE col.attidentity
                WHEN 'a' THEN ' GENERATED ALWAYS AS IDENTITY'
                ELSE ' GENERATED BY DEFAULT AS IDENTITY'
            END;
            IF col.identity_seq_name IS NOT NULL THEN
                v_cols := v_cols || format(
                    ' (SEQUENCE NAME %I.%I INCREMENT BY %s MINVALUE %s MAXVALUE %s START WITH %s CACHE %s %s)',
                    col.identity_seq_schema, col.identity_seq_name,
                    col.identity_seq_increment, col.identity_seq_min,
                    col.identity_seq_max, col.identity_seq_start,
                    col.identity_seq_cache,
                    CASE WHEN col.identity_seq_cycle THEN 'CYCLE' ELSE 'NO CYCLE' END
                );
            END IF;
        ELSIF col.default_expr IS NOT NULL THEN
            v_cols := v_cols || ' DEFAULT ' || col.default_expr;
        END IF;
        v_select := v_select || format('%I', col.attname);
    END LOOP;

    -- Find views that depend directly or indirectly on the target.  They are
    -- dropped deepest-first and recreated shallowest-first.
    FOR view_record IN
        WITH RECURSIVE dependent_views(oid, depth, path) AS (
            SELECT v.oid, 1, ARRAY[v.oid]
              FROM pg_class v
              JOIN pg_rewrite r ON r.ev_class = v.oid
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = v_oid
             WHERE v.relkind = 'v'
            UNION ALL
            SELECT v.oid, dv.depth + 1, dv.path || v.oid
              FROM dependent_views dv
              JOIN pg_rewrite r ON true
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = dv.oid
              JOIN pg_class v ON v.oid = r.ev_class
             WHERE v.relkind = 'v'
               AND NOT (v.oid = ANY (dv.path))
        )
        SELECT v.oid, n.nspname AS schemaname, v.relname,
               max(dv.depth) AS depth,
               pg_get_viewdef(v.oid, true) AS definition,
               pg_get_userbyid(v.relowner) AS owner_name
          FROM dependent_views dv
          JOIN pg_class v ON v.oid = dv.oid
          JOIN pg_namespace n ON n.oid = v.relnamespace
         GROUP BY v.oid, n.nspname, v.relname, v.relowner
         ORDER BY max(dv.depth) DESC, n.nspname, v.relname
    LOOP
        v_locks := v_locks || format(
            E'\nLOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE;',
            view_record.schemaname, view_record.relname
        );
        v_drop_views := v_drop_views || format(
            E'\nDROP VIEW %I.%I;',
            view_record.schemaname, view_record.relname
        );
    END LOOP;

    FOR view_record IN
        WITH RECURSIVE dependent_views(oid, depth, path) AS (
            SELECT v.oid, 1, ARRAY[v.oid]
              FROM pg_class v
              JOIN pg_rewrite r ON r.ev_class = v.oid
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = v_oid
             WHERE v.relkind = 'v'
            UNION ALL
            SELECT v.oid, dv.depth + 1, dv.path || v.oid
              FROM dependent_views dv
              JOIN pg_rewrite r ON true
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = dv.oid
              JOIN pg_class v ON v.oid = r.ev_class
             WHERE v.relkind = 'v'
               AND NOT (v.oid = ANY (dv.path))
        )
        SELECT v.oid, n.nspname AS schemaname, v.relname,
               max(dv.depth) AS depth,
               pg_get_viewdef(v.oid, true) AS definition
          FROM dependent_views dv
          JOIN pg_class v ON v.oid = dv.oid
          JOIN pg_namespace n ON n.oid = v.relnamespace
         GROUP BY v.oid, n.nspname, v.relname
         ORDER BY max(dv.depth), n.nspname, v.relname
    LOOP
        IF obj_description(view_record.oid, 'pg_class') IS NOT NULL THEN
            v_view_comments := v_view_comments || format(
                E'\nCOMMENT ON VIEW %I.%I IS %L;',
                view_record.schemaname, view_record.relname,
                obj_description(view_record.oid, 'pg_class')
            );
        END IF;
        FOR comment_record IN
            SELECT a.attname, col_description(view_record.oid, a.attnum) AS description
              FROM pg_attribute a
             WHERE a.attrelid = view_record.oid
               AND a.attnum > 0
               AND NOT a.attisdropped
               AND col_description(view_record.oid, a.attnum) IS NOT NULL
             ORDER BY a.attnum
        LOOP
            v_view_comments := v_view_comments || format(
                E'\nCOMMENT ON COLUMN %I.%I.%I IS %L;',
                view_record.schemaname, view_record.relname,
                comment_record.attname, comment_record.description
            );
        END LOOP;
        v_create_views := v_create_views || format(
            E'\nCREATE VIEW %I.%I AS\n%s;',
            view_record.schemaname, view_record.relname,
            view_record.definition
        );
    END LOOP;

    -- Capture triggers on the target and on dependent views before dropping
    -- either object.  PostgreSQL stores permissions on their parent relation,
    -- not on trigger objects themselves.
    FOR trigger_record IN
        WITH RECURSIVE dependent_views(oid, path) AS (
            SELECT v.oid, ARRAY[v.oid]
              FROM pg_class v
              JOIN pg_rewrite r ON r.ev_class = v.oid
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = v_oid
             WHERE v.relkind = 'v'
            UNION ALL
            SELECT v.oid, dv.path || v.oid
              FROM dependent_views dv
              JOIN pg_rewrite r ON true
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = dv.oid
              JOIN pg_class v ON v.oid = r.ev_class
             WHERE v.relkind = 'v'
               AND NOT (v.oid = ANY (dv.path))
        )
        SELECT t.oid, t.tgname, t.tgrelid,
               n.nspname AS schemaname, c.relname,
               pg_get_triggerdef(t.oid, true) AS definition
          FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE NOT t.tgisinternal
           AND (t.tgrelid = v_oid OR t.tgrelid IN (SELECT oid FROM dependent_views))
         ORDER BY CASE WHEN t.tgrelid = v_oid THEN 0 ELSE 1 END,
                  n.nspname, c.relname, t.tgname
    LOOP
        v_drop_triggers := v_drop_triggers || format(
            E'\nDROP TRIGGER %I ON %I.%I;',
            trigger_record.tgname, trigger_record.schemaname,
            trigger_record.relname
        );
        v_create_triggers := v_create_triggers || E'\n' ||
            trigger_record.definition || ';';
    END LOOP;

    -- Save relation owners and ACL entries for the target and dependent views.
    FOR permission_record IN
        WITH RECURSIVE dependent_views(oid, path) AS (
            SELECT v.oid, ARRAY[v.oid]
              FROM pg_class v
              JOIN pg_rewrite r ON r.ev_class = v.oid
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = v_oid
             WHERE v.relkind = 'v'
            UNION ALL
            SELECT v.oid, dv.path || v.oid
              FROM dependent_views dv
              JOIN pg_rewrite r ON true
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = dv.oid
              JOIN pg_class v ON v.oid = r.ev_class
             WHERE v.relkind = 'v'
               AND NOT (v.oid = ANY (dv.path))
        ), object_relations(oid) AS (
            SELECT v_oid
            UNION
            SELECT oid FROM dependent_views
        )
        SELECT n.nspname AS schemaname, c.relname,
               pg_get_userbyid(c.relowner) AS owner_name
          FROM object_relations o
          JOIN pg_class c ON c.oid = o.oid
          JOIN pg_namespace n ON n.oid = c.relnamespace
    LOOP
        v_permissions := v_permissions || format(
            E'\nALTER %s %I.%I OWNER TO %I;',
            CASE WHEN permission_record.relname = v_relname
                 AND permission_record.schemaname = v_schema
                 THEN 'TABLE' ELSE 'VIEW' END,
            permission_record.schemaname, permission_record.relname,
            permission_record.owner_name
        );
    END LOOP;

    FOR permission_record IN
        WITH RECURSIVE dependent_views(oid, path) AS (
            SELECT v.oid, ARRAY[v.oid]
              FROM pg_class v
              JOIN pg_rewrite r ON r.ev_class = v.oid
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = v_oid
             WHERE v.relkind = 'v'
            UNION ALL
            SELECT v.oid, dv.path || v.oid
              FROM dependent_views dv
              JOIN pg_rewrite r ON true
              JOIN pg_depend d
                ON d.classid = 'pg_rewrite'::regclass
               AND d.objid = r.oid
               AND d.refclassid = 'pg_class'::regclass
               AND d.refobjid = dv.oid
              JOIN pg_class v ON v.oid = r.ev_class
             WHERE v.relkind = 'v'
               AND NOT (v.oid = ANY (dv.path))
        ), object_relations(oid) AS (
            SELECT v_oid
            UNION
            SELECT oid FROM dependent_views
        )
        SELECT n.nspname AS schemaname, c.relname,
               x.grantee, x.privilege_type, x.is_grantable
          FROM object_relations o
          JOIN pg_class c ON c.oid = o.oid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(
              COALESCE(c.relacl, acldefault('r', c.relowner))
          ) AS x
    LOOP
        grantee_name := CASE
            WHEN permission_record.grantee = 0 THEN 'PUBLIC'
            ELSE format('%I', pg_get_userbyid(permission_record.grantee))
        END;
        v_permissions := v_permissions || format(
            E'\nGRANT %s ON TABLE %I.%I TO %s%s;',
            permission_record.privilege_type,
            permission_record.schemaname, permission_record.relname,
            grantee_name,
            CASE WHEN permission_record.is_grantable
                 THEN ' WITH GRANT OPTION' ELSE '' END
        );
    END LOOP;

    -- Lock the target and every table with an inbound FK.  Referenced tables
    -- for outbound FKs do not need to be locked because their constraints are
    -- not modified.
    FOR affected_table IN
        SELECT DISTINCT n.nspname, c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.oid IN (
             SELECT v_oid
             UNION
             SELECT conrelid FROM pg_constraint
              WHERE contype = 'f'
                AND confrelid = v_oid
         )
         ORDER BY n.nspname, c.relname
    LOOP
        v_locks := v_locks || format(
            E'\nLOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE;',
            affected_table.nspname, affected_table.relname
        );
    END LOOP;

    -- Inbound FKs must be removed before the old table's primary/unique
    -- constraints can be dropped.  Self-referencing FKs are included once.
    FOR constraint_record IN
            SELECT c.oid, c.conrelid, c.conname,
                   n.nspname AS relschema, r.relname,
                   pg_get_constraintdef(c.oid, true) AS definition
              FROM pg_constraint c
              JOIN pg_class r ON r.oid = c.conrelid
              JOIN pg_namespace n ON n.oid = r.relnamespace
             WHERE c.contype = 'f'
               AND (c.conrelid = v_oid OR c.confrelid = v_oid)
             ORDER BY n.nspname, r.relname, c.conname
    LOOP
        IF constraint_record.conrelid <> v_oid THEN
            v_drop_fks := v_drop_fks || format(
                E'\nALTER TABLE %I.%I DROP CONSTRAINT %I;',
                constraint_record.relschema, constraint_record.relname,
                constraint_record.conname
            );
        END IF;
        v_foreign_keys := v_foreign_keys || format(
            E'\nALTER TABLE %I.%I ADD CONSTRAINT %I %s;',
            constraint_record.relschema, constraint_record.relname,
            constraint_record.conname, constraint_record.definition
        );
    END LOOP;

    -- Recreate every non-FK constraint owned by the table, retaining its
    -- name and definition.  This includes PK, UNIQUE, CHECK, and EXCLUDE.
    FOR constraint_record IN
            SELECT conname, contype, pg_get_constraintdef(oid, true) AS definition
             FROM pg_constraint
             WHERE conrelid = v_oid
               AND contype NOT IN ('f', 'n')
             ORDER BY CASE contype WHEN 'p' THEN 1 WHEN 'u' THEN 2 ELSE 3 END,
                      conname
    LOOP
        v_constraints := v_constraints || format(
            E'\nALTER TABLE %I.%I ADD CONSTRAINT %I %s;',
            v_schema, v_relname, constraint_record.conname,
            constraint_record.definition
        );
    END LOOP;

    -- Constraint-owned indexes are recreated by their constraints.  Every
    -- other index is remembered from PostgreSQL's own DDL and recreated after
    -- the old table is dropped.
    FOR index_record IN
            SELECT i.indexrelid, pg_get_indexdef(i.indexrelid) AS definition,
                   n.nspname AS indexschema, ic.relname AS indexname
              FROM pg_index i
              JOIN pg_class ic ON ic.oid = i.indexrelid
              JOIN pg_namespace n ON n.oid = ic.relnamespace
             WHERE i.indrelid = v_oid
               AND NOT EXISTS (
                   SELECT 1 FROM pg_constraint c
                    WHERE c.conrelid = v_oid
                      AND c.conindid = i.indexrelid
               )
             ORDER BY n.nspname, ic.relname
    LOOP
        v_indexes := v_indexes || E'\n' || index_record.definition || ';';
    END LOOP;
    v_ddl := format(
        E'BEGIN;%s%s%s%s%s\n\nALTER TABLE %I.%I RENAME TO %I;%s\n\nCREATE TABLE %I.%I (\n%s\n);\n\nINSERT INTO %I.%I\nSELECT %s\n  FROM %I.%I;\n\nDROP TABLE %I.%I;%s%s%s%s%s%s%s%s%s\n\nCOMMIT;',
        v_locks, v_drop_triggers, v_drop_views, v_drop_fks,
        v_rename_sequences,
        v_schema, v_relname, v_relname || '_old',
        v_create_sequences,
        v_schema, v_relname, v_cols,
        v_schema, v_relname, v_select,
        v_schema, v_relname || '_old',
        v_schema, v_relname || '_old',
        v_comments, v_restore_sequences, v_constraints, v_foreign_keys, v_indexes,
        v_create_views, v_view_comments, v_create_triggers, v_permissions
    );

    RETURN v_ddl;
END;
$$;
