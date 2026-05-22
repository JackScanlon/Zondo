\connect dbinst;

/* add fts extensions */
create extension if not exists pg_trgm;
create extension if not exists btree_gin;
create extension if not exists fuzzystrmatch;


/* create tsvector aggregate fn */
do $tx$
begin
  create aggregate tsvector_agg(tsvector) (
    stype = pg_catalog.tsvector,
    sfunc = pg_catalog.tsvector_concat,
    initcond = ''
  );
exception
  when duplicate_function then null;
end;
$tx$ language plpgsql;


/* init lang configuration */
do $tx$
begin
  create text search configuration public.ontology_en (
    copy = pg_catalog.english
  );

  create text search dictionary public.ontology_en_hunspell (
    template  = ispell,
    dictfile  = en_gb,
    afffile   = en_gb,
    stopwords = english
  );

  create text search dictionary public.ontology_en_thesaurus (
    template   = thesaurus,
    dictfile   = en_ontology,
    dictionary = pg_catalog.english_stem
  );

  alter text search configuration public.ontology_en
    alter mapping
      for asciiword, asciihword, hword_asciipart, word, hword, hword_part
     with ontology_en_hunspell, english_stem;

  alter text search configuration public.ontology_en
    alter mapping
      for asciiword, asciihword, hword_asciipart
     with ontology_en_thesaurus, ontology_en_hunspell, english_stem;
exception
  when unique_violation then null;
  when others then raise;
end;
$tx$ language plpgsql;


/* create trigger(s) */
create or replace function ot_gin_tgram_trigger()
  returns trigger
  language plpgsql
as $bd$
declare
  v_synVec tsvector;
  v_relVec tsvector;
begin
    if (new.properties is not null and jsonb_typeof(new.properties->'synonyms') = 'array') then
      v_synVec := jsonb_to_tsvector('public.ontology_en', new.properties->'synonyms', '["string"]');
    end if;

    if (new.properties is not null and jsonb_typeof(new.properties->'xrefs') = 'array') then
      with rels as (
        select jsonb_agg(regexp_replace(ref, '(\w+)(\.\w+)?:(\w+)', '\1\3', 'g')) as vec
          from jsonb_array_elements_text(new.properties->'xrefs') as ref
      )
        select jsonb_to_tsvector('public.ontology_en', vec, '["string"]')
          into v_relVec
          from rels;
    end if;

    new.synonyms_vector := case
      when v_synVec is not null then (
        setweight(to_tsvector('public.ontology_en', new.name), 'A') ||
        setweight(v_synVec, 'A')
      )
      else setweight(to_tsvector('public.ontology_en', new.name), 'A')
    end;

    new.relation_vector := case
      when v_synVec is not null then (
        setweight(to_tsvector('public.ontology_en', replace(lower(new.reference_id), ':', '')), 'A') ||
        setweight(v_relVec, 'A')
      )
      else setweight(to_tsvector('public.ontology_en', replace(lower(new.reference_id), ':', '')), 'A')
    end;

    new.search_vector :=
        setweight(to_tsvector('public.ontology_en', new.name), 'A') ||
        setweight(to_tsvector('public.ontology_en', replace(lower(new.reference_id), ':', '')), 'A') ||
        setweight(coalesce(new.synonyms_vector, to_tsvector('')), 'B') ||
        setweight(coalesce(new.relation_vector, to_tsvector('')), 'C');

    return new;
end;
$bd$;


/* create ontology tables */
do $tx$
declare
  v_refid          bigint := 0;
  v_count         integer := 0;
  v_pages         integer := 0;
  v_chunks        integer := 1000;
  v_starttime timestamptz := clock_timestamp();
  v_timestamp timestamptz := clock_timestamp();
begin
  --! drop table(s)
  if exists(
    select 1
      from information_schema.tables
    where table_schema = 'public'
      and (table_name = 'clinicalcode_ontologytag' or table_name = 'clinicalcode_ontologytagedge')
  ) then
    drop table if exists public.clinicalcode_ontologytag     cascade;
    drop table if exists public.clinicalcode_ontologytagedge cascade;
  end if;

  --! create table(s)
  create table public.clinicalcode_ontologytag(
    id              bigserial    primary key,
    name            varchar(255) not null,
    type_id         integer      not null,
    reference_id    varchar(64)  not null,
    properties      jsonb        default '{}'::jsonb,
    search_vector   tsvector     default '',
    synonyms_vector tsvector     default '',
    relation_vector tsvector     default '',

    unique (type_id, reference_id)
  );

  create table public.clinicalcode_ontologytagedge(
    id        bigserial primary key,
    child_id  bigint    references public.clinicalcode_ontologytag (id) not null,
    parent_id bigint    references public.clinicalcode_ontologytag (id) not null,

    unique (child_id, parent_id)
  );

  --! create temporary table(s)
  create temporary table tmp_ont_cats(
    id         bigint not null,
    categories jsonb  not null
  );

  create temporary table tmp_ont_edges(
    id        bigserial   primary key,
    child_id  varchar(64) not null,
    parent_id varchar(64) not null
  );

  --! create ontological fn(s)
  create or replace function get_ontological_ancestors(node_ids bigint[])
    returns table(
      node_id  bigint,
      path     bigint[]
    )
    language plpgsql as $fn$
  begin
    return query
      with
        recursive ancestors(child_id, parent_id, depth, path) as (
          select
              first.child_id,
              first.parent_id,
              1 as depth,
              array[first.child_id] as path
            from public.clinicalcode_ontologytagedge as first
           where first.child_id = any(node_ids)
           union all
          select
              first.child_id,
              first.parent_id,
              second.depth + 1 as depth,
              second.path || first.child_id as path
            from public.clinicalcode_ontologytagedge as first,
                 ancestors as second
           where first.child_id = second.parent_id
             and first.child_id <> all(second.path)
        )
      select
          p.child_id as node_id,
          p.path as path
        from ancestors as p;
  end
  $fn$;

  create or replace function get_ontological_categories(node_ids bigint[], from_root bigint)
    returns table(
      id         bigint,
      categories jsonb
    )
    language plpgsql as $fn$
  begin
    return query
      with
        paths as (
          select ont.id, ancestors.path[array_length(ancestors.path, 1) - 1] as cat_id
            from public.clinicalcode_ontologytag as ont,
                 get_ontological_ancestors(node_ids) as ancestors
           where ancestors.node_id = from_root
             and array_length(ancestors.path, 1) > 1
        )
      select
          p.id,
          jsonb_agg(distinct jsonb_build_object(
            'name', n.name,
            'ref', n.reference_id
          )) as categories
        from paths as p
        join public.clinicalcode_ontologytag as n
          on n.id = p.cat_id
       group by p.id;
  end
  $fn$;

  --! copy data
  raise notice '[EDGES] Copy relationships';
  copy tmp_ont_edges(
    child_id,
    parent_id
  )
    from '/var/lib/postgresql/csvs/mondo_rels.csv'
    with (
      format      'csv',
      header       'on',
      encoding  'UTF-8',
      quote         '|',
      escape        '|',
      delimiter     ','
    );

  raise notice '[NODES] Copy terms';
  copy public.clinicalcode_ontologytag(
    name,
    type_id,
    reference_id,
    properties
  )
    from '/var/lib/postgresql/csvs/mondo_terms.csv'
    with (
      format      'csv',
      header       'on',
      encoding  'UTF-8',
      quote         '|',
      escape        '|',
      delimiter     ','
    );

  --! create edge indices
  ---- hash indices
  raise notice '[EDGES] Create hash indices';
  create index if not exists oe_hh_id_idx
      on public.clinicalcode_ontologytagedge
      using hash(id);

  create index if not exists oe_hh_chid_idx
      on public.clinicalcode_ontologytagedge
      using hash(child_id);

  create index if not exists oe_hh_prid_idx
      on public.clinicalcode_ontologytagedge
      using hash(parent_id);

  ---- composite indices
  raise notice '[EDGES] Create composite indices';
  create index if not exists oe_cpbt_chpr_idx
      on public.clinicalcode_ontologytagedge
      using btree(child_id, parent_id);

  ---- covering indices
  raise notice '[EDGES] Create covering indices';
  create index if not exists oe_cv_ch_idx
      on public.clinicalcode_ontologytagedge(child_id)
      include (id, parent_id);

  create index if not exists oe_cv_pr_idx
      on public.clinicalcode_ontologytagedge(parent_id)
      include (id, child_id);

  --! create ontology indices
  ---- hash & btree indices
  raise notice '[NODES] Create hash & btree indices';
  create index if not exists ot_hh_id_idx
      on public.clinicalcode_ontologytag
      using hash(id);

  create index if not exists ot_bt_tp_idx
      on public.clinicalcode_ontologytag
      using btree(type_id);

  create index if not exists ot_bt_ref_idx
      on public.clinicalcode_ontologytag
      using btree(reference_id);

  ---- composite indices
  raise notice '[NODES] Create composite indices';
  create index if not exists ot_cpbt_tr_idx
      on public.clinicalcode_ontologytag
      using btree(type_id, reference_id);

  ---- jsonb (gin) indices
  raise notice '[NODES] Create jsonb (gin) indices';
  create index if not exists ot_gin_jref_idx
      on public.clinicalcode_ontologytag
      using gin((properties->'xrefs') jsonb_ops);

  create index if not exists ot_gin_jsyn_idx
      on public.clinicalcode_ontologytag
      using gin((properties->'synonyms') jsonb_ops);

  create index if not exists ot_gin_jcat_idx
      on public.clinicalcode_ontologytag
      using gin((properties->'categories') jsonb_ops);

  create index if not exists ot_gin_jdef_idx
      on public.clinicalcode_ontologytag
      using gin((properties->'definition') jsonb_ops);

  ---- search vector (gin) indices
  raise notice '[NODES] Create search vector (gin) indices';
  create index if not exists ot_gin_srch_idx
      on public.clinicalcode_ontologytag
      using gin(search_vector tsvector_ops);

  create index if not exists ot_gin_syns_idx
      on public.clinicalcode_ontologytag
      using gin(synonyms_vector tsvector_ops);

  create index if not exists ot_gin_rels_idx
      on public.clinicalcode_ontologytag
      using gin(relation_vector tsvector_ops);

  ---- covering indices
  raise notice '[NODES] Create covering indices';
  create index if not exists ot_cv_id_idx
      on public.clinicalcode_ontologytag(id)
      include (name, type_id, reference_id);

  create index if not exists ot_cv_tid_idx
      on public.clinicalcode_ontologytag(type_id)
      include (id, name, reference_id);

  create index if not exists ot_cv_ref_idx
      on public.clinicalcode_ontologytag(reference_id)
      include (id, name, type_id);

  create index if not exists ot_cv_tr_idx
      on public.clinicalcode_ontologytag(type_id, reference_id)
      include (id, name);

  --! build edges
  raise notice '[EDGES] Build relationships';
  insert into public.clinicalcode_ontologytagedge(
    child_id,
    parent_id
  )
    select
        child.id as child_id,
        parent.id as parent_id
      from tmp_ont_edges as edge
      join public.clinicalcode_ontologytag as child
        on edge.child_id = child.reference_id
      join public.clinicalcode_ontologytag as parent
        on edge.parent_id = parent.reference_id;

  --! update node properties
  raise notice '[NODES] Resolve disease root node';
  select n.id
    into v_refid
    from public.clinicalcode_ontologytag as n
   where n.reference_id = 'MONDO:7770006'; --? "disease by body system or component"

  raise notice '[NODES] Build node categories from Root<%>', v_refid;
  with
    paths as (
      select ont.id, ancestors.path[array_length(ancestors.path, 1) - 1] as cat_id
        from public.clinicalcode_ontologytag as ont,
             get_ontological_ancestors(array[ont.id]::bigint[]) as ancestors
       where ancestors.node_id = v_refid
         and array_length(ancestors.path, 1) > 1
    )
  insert into tmp_ont_cats(id, categories)
    select
        p.id,
        jsonb_agg(distinct jsonb_build_object(
          'name', n.name,
          'ref', n.reference_id
        )) as categories
      from paths as p
      join public.clinicalcode_ontologytag as n
        on n.id = p.cat_id
      group by p.id;

  raise notice '[NODES] Update node categories';
  update public.clinicalcode_ontologytag as ont
     set properties['categories'] = c.categories
    from tmp_ont_cats as c
   where c.id = ont.id
     and jsonb_typeof(c.categories) = 'array'
     and jsonb_array_length(c.categories) > 0;

  --! drop temp table(s)
  drop table tmp_ont_cats;
  drop table tmp_ont_edges;

  --! create trigger
  raise notice '[TRIGGER] Install trigger';
  create trigger ot_search_vec_tr
  before insert or update
      on public.clinicalcode_ontologytag
  for each row
      execute function ot_gin_tgram_trigger();

  --! force trigger
  ---- compute chunks
  select count(*)
    into v_count
    from public.clinicalcode_ontologytag;

  v_pages := ceil(v_count / v_chunks)::int;

  ---- update chunks
  v_starttime := clock_timestamp();

  for i in 0..v_pages loop
    v_timestamp := clock_timestamp();

    update public.clinicalcode_ontologytag
        set search_vector = null
      where id between i*v_chunks and ((i + 1)*v_chunks - 1);

    raise notice '[TRIGGER::Op<Progress: %, Runtime: %>] Updated Chunk<start: %, end: %, time: %s>',
                  lpad(concat(round((i::numeric/v_pages::numeric)*100, 2), '%'), 7, ' '),
                  to_char(clock_timestamp() - v_starttime, 'HH24:MI:SS'),
                  lpad((i*v_chunks)::text, 5, ' '),
                  lpad(((i + 1)*v_chunks - 1)::text, 5, ' '),
                  round(extract(epoch from clock_timestamp() - v_timestamp), 2);
  end loop;

end;
$tx$ language plpgsql;
