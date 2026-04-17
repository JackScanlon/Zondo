\connect dbinst;

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
