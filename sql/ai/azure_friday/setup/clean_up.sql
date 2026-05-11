DELETE FROM ai.pipelines WHERE name = 'product_rag_pipeline';
DROP TABLE IF EXISTS product_rag_pipeline_output CASCADE;