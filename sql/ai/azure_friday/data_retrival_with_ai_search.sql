SELECT setup_index_for_search('product_rag_pipeline_output');

-- 1. Seating
SELECT output.id, output.chunk_text as product, search.score
FROM ai.search(
    query => 'mid-century modern furniture for Brooklyn loft living room with wood tones and dark vibe',
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter => 'category = ''Chairs'''
    ) search
JOIN product_rag_pipeline_output output ON output.id = search.id;