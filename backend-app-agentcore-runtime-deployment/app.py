import os
import json
import numpy as np
import re
import time
import boto3
import traceback
from botocore.exceptions import ClientError
from botocore.config import Config
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent, tool
from strands.models import BedrockModel

# ==== AWS config with defaults for local testing ====
s3_vector_bucket = os.environ["VECTOR_BUCKET_NAME"]
index_name = os.environ["INDEX_NAME"]
model_id = os.environ["MODEL_ID"]
reasoning_model_id = os.environ["REASONING_MODEL_ID"]
aws_region = os.environ["AWS_REGION"]

# Log all environment variables for debugging
print("\n==== DEBUG: App startup environment ====")
print("VECTOR_BUCKET_NAME:", s3_vector_bucket)
print("INDEX_NAME:", index_name)
print("MODEL_ID:", model_id)
print("REASONING_MODEL_ID:", reasoning_model_id)
print("REGION:", aws_region)
print("All environment variables:", {k: v for k, v in os.environ.items() if k in [
    "VECTOR_BUCKET_NAME", "INDEX_NAME", "MODEL_ID", "REASONING_MODEL_ID", "REGION", "AWS_DEFAULT_REGION"
]})
print("========================================\n")

# Validate environment variables
missing_vars = []
for var, value in [
    ("VECTOR_BUCKET_NAME", s3_vector_bucket),
    ("INDEX_NAME", index_name),
    ("MODEL_ID", model_id),
    ("REASONING_MODEL_ID", reasoning_model_id),
    ("REGION", aws_region)
]:
    if not value:
        missing_vars.append(var)

if missing_vars:
    error_msg = f"ERROR: Missing required environment variables: {', '.join(missing_vars)}. Using defaults for local testing."
    print(f"DEBUG: {error_msg}")
else:
    print("DEBUG: All required environment variables are set.")

app = BedrockAgentCoreApp()

def get_aws_session():
    session = boto3.Session(region_name=aws_region)
    print(f"DEBUG: boto3.Session region_name={session.region_name}")
    return session, None

@tool
def search_transcripts(query: str) -> dict:
    global model_id, s3_vector_bucket, index_name
    print(f"\n==== DEBUG: search_transcripts START ====")
    print(f"Query: {query}, Index: {index_name}, Model: {model_id}, Bucket: {s3_vector_bucket}")
    start_time = time.time()

    session = get_aws_session()[0]
    bedrock_config = Config(retries={'max_attempts': 3, 'mode': 'standard'})
    s3vectors_config = Config(retries={'max_attempts': 3, 'mode': 'standard'})

    try:
        bedrock = session.client('bedrock-runtime', config=bedrock_config)
        s3vectors = session.client('s3vectors', config=s3vectors_config)
    except ClientError as e:
        return {"output": {"message": f"ClientError: {e}"}}

    print(f"DEBUG: Bedrock region: {bedrock.meta.region_name}, S3Vectors region: {s3vectors.meta.region_name}")

    try:
        # 1️⃣ Infer persona with confidence
        persona_start = time.time()
        query_lower = query.lower()
        leadership_terms = ["ciso", "leader", "leadership", "executive", "manager", "governance", "strategy", "compliance", "policy", "risk", "identity", "security", "authentication", "authorization"]
        technical_terms = ["engineer", "developer", "implementation", "api", "code", "technical", "tool", "sdk", "programming", "configuration", "mcp", "bedrock", "cognito"]
        leadership_conf = sum(query_lower.count(term) for term in leadership_terms) / max(1, len(query_lower.split()))
        technical_conf = sum(query_lower.count(term) for term in technical_terms) / max(1, len(query_lower.split()))
        persona = "leadership" if leadership_conf > technical_conf else "technical" if technical_conf > leadership_conf else "general"
        print(f"DEBUG: Inferred persona: {persona}, leadership_conf={leadership_conf:.3f}, technical_conf={technical_conf:.3f}")
        print(f"DEBUG: Persona inference time: {time.time() - persona_start:.3f}s")

        # Adjust weights based on persona
        semantic_weight = 0.8 if persona == "leadership" else 0.6 if persona == "technical" else 0.7
        keyword_weight = 1.0 - semantic_weight - 0.05
        print(f"DEBUG: Weights - semantic: {semantic_weight}, keyword: {keyword_weight}, metadata: 0.05")

        # 2️⃣ Generate embedding from Bedrock
        embed_start = time.time()
        embedding_response = bedrock.invoke_model(
            modelId=model_id,
            body=json.dumps({"inputText": query})
        )
        body = embedding_response['body'].read()
        embedding_data = json.loads(body)
        if 'embedding' not in embedding_data:
            return {"output": {"message": "NO_RELEVANT_OUTPUT"}}
        query_embedding = np.array(embedding_data['embedding'])
        print(f"DEBUG: Embedding generation time: {time.time() - embed_start:.3f}s")

        # 3️⃣ Vector search (initial attempt with topK=10)
        search_start = time.time()
        vector_query = {
            "indexName": index_name,
            "vectorBucketName": s3_vector_bucket,
            "queryVector": {"float32": query_embedding.tolist()},
            "topK": 10,
            "returnMetadata": True,
            "returnDistance": True
        }
        vector_response = s3vectors.query_vectors(**vector_query)
        if not vector_response.get('vectors'):
            return {"output": {"message": "NO_RELEVANT_OUTPUT"}}
        print(f"DEBUG: Vector search time: {time.time() - search_start:.3f}s")

        # 4️⃣ Build hybrid scoring with metadata boost
        score_start = time.time()
        candidates = []
        keywords = [kw for kw in query_lower.split() if len(kw) >= 2]
        synonyms = {
            "ciso": ["chief information security officer", "security officer"],
            "ai": ["artificial intelligence", "machine learning"],
            "security": ["cybersecurity", "protection", "secure"],
            "agentic": ["agent", "autonomous", "intelligent"],
            "leader": ["executive", "manager", "director"],
            "engineer": ["developer", "programmer", "technical"]
        }
        all_keywords = keywords + [syn for kw in keywords for syn in synonyms.get(kw, [])]
        print(f"DEBUG: Keywords: {keywords}, Synonyms: {all_keywords}")

        for result in vector_response['vectors']:
            content = result.get('metadata', {}).get('source_text', '')
            content_lower = content.lower()
            sem_score = 1 - result.get('distance', 1.0)
            kw_score = sum(content_lower.count(kw) for kw in all_keywords) / max(1, len(content_lower.split()))

            # Metadata boost using summary, topics, and source_text
            metadata = result.get('metadata', {})
            summary = metadata.get('Video Transcript Summary', 'No summary available.')
            sentences = summary.split('.')
            summary = '. '.join(sentences[:2]).strip() + ('.' if sentences else '')
            topics = metadata.get('When Was Each Topic Discussed', '').lower()
            combined_text = content_lower + ' ' + summary.lower() + ' ' + topics
            matched_terms = []
            metadata_score = 0.0
            if persona == "leadership":
                metadata_score = sum(combined_text.count(term) for term in leadership_terms) / max(1, len(combined_text.split()))
                matched_terms = [term for term in leadership_terms if term in combined_text]
            elif persona == "technical":
                metadata_score = sum(combined_text.count(term) for term in technical_terms) / max(1, len(combined_text.split()))
                matched_terms = [term for term in technical_terms if term in combined_text]

            candidates.append({
                'doc_id': result['key'],
                'content': content,
                'metadata': metadata,
                'summary': summary,
                'semantic_score': sem_score,
                'keyword_score': kw_score,
                'metadata_score': metadata_score,
                'matched_terms': matched_terms
            })

        # Normalize scores and blend
        max_kw = max((c['keyword_score'] for c in candidates), default=0.0)
        max_meta = max((c['metadata_score'] for c in candidates), default=0.0)
        for c in candidates:
            norm_kw = (c['keyword_score'] / max_kw) if max_kw > 0 else 0.0
            norm_meta = (c['metadata_score'] / max_meta) if max_meta > 0 else 0.0
            c['hybrid_score'] = semantic_weight * c['semantic_score'] + keyword_weight * norm_kw + 0.05 * norm_meta
            print(f"DEBUG: Candidate {c['doc_id']}: semantic_score={c['semantic_score']}, keyword_score={c['keyword_score']}, metadata_score={c['metadata_score']}, matched_terms={c['matched_terms']}, hybrid_score={c['hybrid_score']}")
        print(f"DEBUG: Scoring time: {time.time() - score_start:.3f}s")

        # 5️⃣ Cluster for diversity (prioritize leadership for CISO queries)
        cluster_start = time.time()
        leadership_candidates = [c for c in candidates if sum(c['content'].lower().count(t) for t in leadership_terms) >= sum(c['content'].lower().count(t) for t in technical_terms)]
        technical_candidates = [c for c in candidates if c not in leadership_candidates]
        top_docs = []
        if persona == "leadership" and leadership_candidates:
            leadership_candidates.sort(key=lambda x: x['hybrid_score'], reverse=True)
            top_docs.extend(leadership_candidates[:2])
            if len(top_docs) < 2 and technical_candidates:
                technical_candidates.sort(key=lambda x: x['hybrid_score'], reverse=True)
                top_docs.append(technical_candidates[0])
        else:
            candidates.sort(key=lambda x: x['hybrid_score'], reverse=True)
            top_docs = candidates[:5]
        print(f"DEBUG: Clustering time: {time.time() - cluster_start:.3f}s")

        # 6️⃣ Collect results with valid links
        link_start = time.time()
        valid_results = []
        for doc in top_docs:
            metadata = doc.get('metadata', {})
            links = {}
            for key, value in [
                ("external_youtube_link", metadata.get("External Youtube Link", "")),
                ("content_link", metadata.get("Content Link", "")),
                ("deck_link", metadata.get("Deck Link", "")),
                ("internal_broadcast_link", metadata.get("Internal Broadcast Video Link", ""))
            ]:
                if value and value.lower() not in ["not available", ""]:
                    links[key] = value
            if links:
                valid_results.append({
                    "doc_id": doc['doc_id'],
                    "links": links,
                    "hybrid_score": doc['hybrid_score'],
                    "summary": doc['summary']
                })
        print(f"DEBUG: Link filtering time: {time.time() - link_start:.3f}s")

        # 7️⃣ If fewer than 2 results with valid links, retry with topK=15
        if len(valid_results) < 2:
            retry_start = time.time()
            print(f"DEBUG: Found {len(valid_results)} videos with valid links, retrying with topK=15")
            vector_query["topK"] = 15
            vector_response = s3vectors.query_vectors(**vector_query)
            if vector_response.get('vectors'):
                candidates = []
                for result in vector_response['vectors']:
                    content = result.get('metadata', {}).get('source_text', '')
                    content_lower = content.lower()
                    sem_score = 1 - result.get('distance', 1.0)
                    kw_score = sum(content_lower.count(kw) for kw in all_keywords) / max(1, len(content_lower.split()))
                    metadata = result.get('metadata', {})
                    summary = metadata.get('Video Transcript Summary', 'No summary available.')
                    sentences = summary.split('.')
                    summary = '. '.join(sentences[:2]).strip() + ('.' if sentences else '')
                    topics = metadata.get('When Was Each Topic Discussed', '').lower()
                    combined_text = content_lower + ' ' + summary.lower() + ' ' + topics
                    matched_terms = []
                    metadata_score = 0.0
                    if persona == "leadership":
                        metadata_score = sum(combined_text.count(term) for term in leadership_terms) / max(1, len(combined_text.split()))
                        matched_terms = [term for term in leadership_terms if term in combined_text]
                    elif persona == "technical":
                        metadata_score = sum(combined_text.count(term) for term in technical_terms) / max(1, len(combined_text.split()))
                        matched_terms = [term for term in technical_terms if term in combined_text]

                    candidates.append({
                        'doc_id': result['key'],
                        'content': content,
                        'metadata': metadata,
                        'summary': summary,
                        'semantic_score': sem_score,
                        'keyword_score': kw_score,
                        'metadata_score': metadata_score,
                        'matched_terms': matched_terms
                    })

                # Normalize and blend scores
                max_kw = max((c['keyword_score'] for c in candidates), default=0.0)
                max_meta = max((c['metadata_score'] for c in candidates), default=0.0)
                for c in candidates:
                    norm_kw = (c['keyword_score'] / max_kw) if max_kw > 0 else 0.0
                    norm_meta = (c['metadata_score'] / max_meta) if max_meta > 0 else 0.0
                    c['hybrid_score'] = semantic_weight * c['semantic_score'] + keyword_weight * norm_kw + 0.05 * norm_meta
                    print(f"DEBUG: Candidate {c['doc_id']}: semantic_score={c['semantic_score']}, keyword_score={c['keyword_score']}, metadata_score={c['metadata_score']}, matched_terms={c['matched_terms']}, hybrid_score={c['hybrid_score']}")
                print(f"DEBUG: Scoring time: {time.time() - score_start:.3f}s")

                # Cluster again
                leadership_candidates = [c for c in candidates if sum(c['content'].lower().count(t) for t in leadership_terms) >= sum(c['content'].lower().count(t) for t in technical_terms)]
                technical_candidates = [c for c in candidates if c not in leadership_candidates]
                top_docs = []
                if persona == "leadership" and leadership_candidates:
                    leadership_candidates.sort(key=lambda x: x['hybrid_score'], reverse=True)
                    top_docs.extend(leadership_candidates[:2])
                    if len(top_docs) < 2 and technical_candidates:
                        technical_candidates.sort(key=lambda x: x['hybrid_score'], reverse=True)
                        top_docs.append(technical_candidates[0])
                else:
                    candidates.sort(key=lambda x: x['hybrid_score'], reverse=True)
                    top_docs = candidates[:5]

                valid_results = []
                for doc in top_docs:
                    metadata = doc.get('metadata', {})
                    links = {}
                    for key, value in [
                        ("external_youtube_link", metadata.get("External Youtube Link", "")),
                        ("content_link", metadata.get("Content Link", "")),
                        ("deck_link", metadata.get("Deck Link", "")),
                        ("internal_broadcast_link", metadata.get("Internal Broadcast Video Link", ""))
                    ]:
                        if value and value.lower() not in ["not available", ""]:
                            links[key] = value
                    if links:
                        valid_results.append({
                            "doc_id": doc['doc_id'],
                            "links": links,
                            "hybrid_score": doc['hybrid_score'],
                            "summary": doc['summary']
                        })
            print(f"DEBUG: Retry search time: {time.time() - retry_start:.3f}s")

        # 8️⃣ Prepare output
        output_start = time.time()
        if len(valid_results) < 2:
            return {
                "output": {
                    "message": f"ERROR: Found only {len(valid_results)} video(s) with valid links; at least 2 required",
                    "results": valid_results,
                    "final_recommendation": "Insufficient relevant videos found to provide a recommendation."
                }
            }

        # Take top 2 results with valid links
        filtered_results = valid_results[:2]

        # 9️⃣ Generate final recommendation
        final_recommendation = "No relevant results found."
        if filtered_results:
            recommendation_level = "Highly recommended" if filtered_results[0]['hybrid_score'] > 0.5 else "Moderately relevant"
            top_summary = filtered_results[0].get('summary', 'No summary available.')
            second_summary = filtered_results[1].get('summary', 'No summary available.')
            final_recommendation = (
                f"{recommendation_level}: Relevant for agentic AI security.\n"
                f"- Video 1 ({filtered_results[0]['doc_id']}): {top_summary}\n"
                f"- Video 2 ({filtered_results[1]['doc_id']}): {second_summary}\n"
                f"Start with Video 1 for its focus on AI agent security."
            )

        print(f"DEBUG: Recommendation generation time: {time.time() - output_start:.3f}s")
        print(f"DEBUG: Total execution time: {time.time() - start_time:.3f}s")

        return {
            "output": {
                "results": [{"doc_id": r["doc_id"], "links": r["links"], "hybrid_score": r["hybrid_score"]} for r in filtered_results],
                "final_recommendation": final_recommendation
            }
        }

    except ClientError as e:
        return {"output": {"message": f"ClientError: {e}"}}
    except Exception as e:
        traceback.print_exc()
        return {"output": {"message": f"Exception: {e}"}}

# ==== Agent setup ====
bedrock_model = BedrockModel(modelId=reasoning_model_id, session=get_aws_session()[0])
content_agent = Agent(
    model=bedrock_model,
    system_prompt="Return the tool's JSON output as a single JSON object without any modifications, narrative, reformatting, or extra text. Do not wrap in a string, array, or add explanations.",
    tools=[search_transcripts]
)

@app.entrypoint
def invoke(payload):
    prompt = payload.get("prompt")
    if not prompt:
        return {"output": {"error": "No prompt provided"}}, 400
    response = content_agent(prompt)
    # Parse response if it's a string or list to extract JSON
    if isinstance(response, (str, list)):
        try:
            if isinstance(response, list):
                response = ''.join(r.strip("b'\"").rstrip("'") for r in response)
            cleaned_response = response.strip("b'\"").rstrip("'").replace("\\\"", "\"").replace("\\\\", "\\")
            return json.loads(cleaned_response)
        except json.JSONDecodeError as e:
            print(f"DEBUG: Failed to parse response as JSON: {e}")
            return {"output": {"message": f"JSONDecodeError: {e}"}}
    return response

if __name__ == "__main__":
    app.run()
