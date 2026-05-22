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
      v_synVec := jsonb_to_tsvector('pg_catalog.english', new.properties->'synonyms', '["string"]');
    end if;

    if (new.properties is not null and jsonb_typeof(new.properties->'xrefs') = 'array') then
      with rels as (
        select jsonb_agg(regexp_replace(ref, '(\w+)(\.\w+)?:(\w+)', '\1\3', 'g')) as vec
          from jsonb_array_elements_text(new.properties->'xrefs') as ref
      )
        select jsonb_to_tsvector('pg_catalog.english', vec, '["string"]')
          into v_relVec
          from rels;
    end if;

    new.synonyms_vector := case
      when v_synVec is not null then (
        setweight(to_tsvector('pg_catalog.english', new.name), 'A') ||
        setweight(v_synVec, 'A')
      )
      else setweight(to_tsvector('pg_catalog.english', new.name), 'A')
    end;

    new.relation_vector := case
      when v_synVec is not null then (
        setweight(to_tsvector('pg_catalog.english', replace(lower(new.reference_id), ':', '')), 'A') ||
        setweight(v_relVec, 'A')
      )
      else setweight(to_tsvector('pg_catalog.english', replace(lower(new.reference_id), ':', '')), 'A')
    end;

    new.search_vector :=
        setweight(to_tsvector('pg_catalog.english', new.name), 'A') ||
        setweight(to_tsvector('pg_catalog.english', replace(lower(new.reference_id), ':', '')), 'A') ||
        setweight(coalesce(new.synonyms_vector, to_tsvector('')), 'B') ||
        setweight(coalesce(new.relation_vector, to_tsvector('')), 'C');

    return new;
end;
$bd$;


/* create ontology tables */
do $tx$
begin
  -- drop table(s)
  drop table if exists public.clinicalcode_ontologytag     cascade;
  drop table if exists public.clinicalcode_ontologytagedge cascade;

  -- create table(s)
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

  -- create table(s)
  create temporary table tmp_ont_nodes(
    name            varchar(255) not null,
    type_id         integer      not null,
    reference_id    varchar(64)  not null,
    properties      jsonb        default '{}'::jsonb,
    search_vector   tsvector     default '',
    synonyms_vector tsvector     default '',
    relation_vector tsvector     default '',

    unique (type_id, reference_id)
  );

  create temporary table tmp_ont_edges(
    child_id  varchar(64) not null,
    parent_id varchar(64) not null
  );

  -- copy data
  copy tmp_ont_nodes(
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

  -- build nodes
  with
    refs as (
      select
          n.reference_id,
          jsonb_agg(regexp_replace(ref, '(\w+)(\.\w+)?:(\w+)', '\1\3', 'g')) as vec
        from tmp_ont_nodes as n,
             jsonb_array_elements_text(n.properties->'xrefs') as ref
       where n.properties is not null
         and jsonb_typeof(n.properties->'xrefs') = 'array'
       group by n.reference_id
    ),
    vecs as (
      select
          n.reference_id,
          case
            when (n.properties is not null and jsonb_typeof(n.properties->'synonyms') = 'array') then (
              setweight(to_tsvector('public.ontology_en', n.name), 'A') ||
              setweight(jsonb_to_tsvector('public.ontology_en', n.properties->'synonyms', '["string"]'), 'A')
            )
            else setweight(to_tsvector('public.ontology_en', n.name), 'A')
          end as synvec,
          case
            when (r.vec is not null) then (
              setweight(to_tsvector('public.ontology_en', replace(lower(n.reference_id), ':', '')), 'A') ||
              setweight(jsonb_to_tsvector('public.ontology_en', vec, '["string"]'), 'A')
            )
            else setweight(to_tsvector('public.ontology_en', replace(lower(n.reference_id), ':', '')), 'A')
          end as relvec
        from tmp_ont_nodes as n
        left join refs as r
          on r.reference_id = n.reference_id
    )
  insert into public.clinicalcode_ontologytag(
    name,
    type_id,
    reference_id,
    properties,
    search_vector,
    synonyms_vector,
    relation_vector
  )
    select
        node.name,
        node.type_id,
        node.reference_id,
        node.properties,
        (
          setweight(to_tsvector('public.ontology_en', node.name), 'A') ||
          setweight(to_tsvector('public.ontology_en', replace(lower(node.reference_id), ':', '')), 'A') ||
          setweight(vec.synvec, 'B') ||
          setweight(vec.relvec, 'C')
        ) as search_vector,
        vec.synvec,
        vec.relvec
      from tmp_ont_nodes as node
      left join vecs as vec
        on vec.reference_id = node.reference_id;

  -- build edges
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

  -- drop temp table(s)
  drop table tmp_ont_nodes;
  drop table tmp_ont_edges;

  -- create indices
  ---- btree & hash indices
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
  create index if not exists ot_cpbt_it_idx
      on public.clinicalcode_ontologytag
      using btree(id, type_id);

  create index if not exists ot_cpbt_tr_idx
      on public.clinicalcode_ontologytag
      using btree(type_id, reference_id);

  ---- jsonb (gin) indices
  create index if not exists ot_gin_jref_idx
      on public.clinicalcode_ontologytag
      using gin((properties->'xrefs') jsonb_ops);

  create index if not exists ot_gin_jsyn_idx
      on public.clinicalcode_ontologytag
      using gin((properties->'synonyms') jsonb_ops);

  ---- search vector (gin) indices
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
  create index if not exists ot_cv_tr_idx
      on public.clinicalcode_ontologytag(type_id, reference_id)
      include (id, name, properties);

  create index if not exists ot_cv_id_idx
      on public.clinicalcode_ontologytag(id)
      include (name, type_id, reference_id, properties);

  create index if not exists ot_cv_id_idx
      on public.clinicalcode_ontologytag(id)
      include (name, type_id, reference_id, properties);

  -- create trigger(s)
  create trigger ot_search_vec_tr
  before insert or update
      on public.clinicalcode_ontologytag
  for each row
      execute function ot_gin_tgram_trigger();
end;
$tx$ language plpgsql;
