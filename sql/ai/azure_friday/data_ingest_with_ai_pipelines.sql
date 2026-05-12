SELECT ai.create_pipeline(
    name    => 'product_rag_pipeline',
    source  => ai.table_source('product_sample', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input => 'title'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                 dimensions => 1536)
    ],
    trigger => 'on_change'
);

SELECT ai.run('product_rag_pipeline');
SELECT count(*) FROM product_rag_pipeline_output;

SELECT ai.pause('product_rag_pipeline'); 
SELECT count(*) FROM product_rag_pipeline_output;

SELECT ai.resume('product_rag_pipeline');
SELECT count(*) FROM product_rag_pipeline_output;