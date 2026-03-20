-- =============================================================================
-- Example: Product Enrichment with Extraction
-- =============================================================================
--
-- Embeds product descriptions and extracts structured fields (category, brand,
-- key features) using GPT-5 Mini. Runs automatically on change with upsert into
-- the product_vectors sink table.
-- =============================================================================

SELECT ai.create_pipeline(
    name    => 'product_enrichment',
    source  => ai.table_source(
                   'products',
                   incremental_column => 'updated_at'
               ),
    steps   => ARRAY[
                   ai.embed(
                       model        => 'text-embedding-3-small',
                       input_column => 'description',
                       batch_size   => 200,
                       dimensions   => 1536
                   ),
                   ai.extract(
                       model        => 'gpt-4.1',
                       input_column => 'description',
                       data         => ARRAY[
                           'category: string - Product category',
                           'brand: string - Brand name',
                           'key_features: string - Top 3 features as JSON array'
                       ]
                   )
               ],
    sink    => ai.table_sink(
                   'product_vectors',
                   on_conflict        => ARRAY['product_id'],
                   on_conflict_action => 'update'
               ),
    trigger => 'on_change'
);