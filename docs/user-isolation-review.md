# User Isolation Implementation Review

**Review Date**: February 26, 2026  
**Updated**: February 26, 2026 (post-implementation follow-ups)  
**Reviewed by**: Claude Sonnet 4.5  
**Branch**: `pinodeca/user-isolation`  
**Commits Reviewed**: 
- `bcd6a77` - E2E tests run as non-superuser
- `67ff26d` - User isolation implementation
- `9ce49c5` - SECURITY DEFINER test
- `661a30e` - USER_GUIDE.md update
- `7debf88` - Dropped role test

**Test Status**: ✅ All unit tests passing, ✅ All E2E tests passing

---

## Executive Summary

The user isolation implementation successfully achieves its core goal: SQL in durable functions now executes with the privileges of the submitting user rather than the background worker's superuser credentials. The implementation closely follows the design document with good code quality and appropriate test coverage for the primary scenarios.

**Key Strengths:**
- Clean separation between identity capture (df.start) and identity usage (execute_sql activity)
- Correct use of `GetOuterUserId()` and `GetSessionUserId()` for privilege isolation
- Comprehensive E2E test covering multiple isolation scenarios
- Good error messages and tracing context

**Critical Gaps:**
- ~~Missing SECURITY DEFINER test (mentioned prominently in design, not implemented)~~ ✅ **RESOLVED** (commit 9ce49c5)
- HTTP activity not isolated (runs with worker privileges) - ✅ **DOCUMENTED** (commit 661a30e)
- ~~No test for dropped/invalid roles~~ ✅ **RESOLVED** (commit 7debf88)
- Variables (df.vars) remain shared across all users with no isolation

**Status Update (Feb 26, 2026)**: All blocking and strongly recommended items have been addressed. The implementation is ready for merge.

---

## 1. Design Document Completeness

### ✅ Well-Covered Areas

The design document is thorough and addresses:
- **Architecture rationale**: Clear explanation of why two user IDs are needed
- **Database schema changes**: Complete DDL with comments
- **Rust implementation details**: Specific functions, types, and code patterns
- **Security model**: Good analysis of trust boundaries and threat model
- **Future work**: Explicitly lists deferred items (connection pooling, RLS, etc.)

### ⚠️ Areas Requiring Clarification

1. **Production pg_hba.conf guidance** (Medium Priority)
   - Design focuses on "local development with pgrx" 
   - Production Docker deployments mentioned but not detailed
   - **Recommendation**: Add section on Docker auth configuration (trust on localhost in container is typical and acceptable)

2. **Error handling for invalid users** (Low Priority)
   - Design mentions dropped role behavior but doesn't specify expected error messages
   - Would benefit from explicit error message format specification
   - **Recommendation**: Document standard error message format for auth failures

3. **Port detection logic** (Low Priority)
   - `get_port()` hardcodes "28817" and checks for ".pgrx" in PGDATA
   - This is implementation detail but brittle
   - **Recommendation**: Consider using a more robust environment variable approach or document the heuristic

---

## 2. Testing Coverage Analysis

### ✅ Tests Implemented

The E2E test `27_user_isolation.sql` covers:
1. ✅ Alice can access her own table (positive case)
2. ✅ Alice cannot access Bob's table (negative case - permission denied)
3. ✅ Bob can access his own table (positive case)
4. ✅ Bob cannot access Alice's table (negative case - permission denied)
5. ✅ SET ROLE with group role (alice connects, SET ROLE analysts)
6. ✅ Identity columns verification (login_role and submitted_by correctly set)

Additional coverage:
- ✅ Non-superuser baseline: Tests now run as `df_e2e_user` (non-privileged)
- ✅ Explicit superuser test: `26_superuser_durable_sql.sql` verifies superuser queries work

### ✅ Previously Missing Tests (Now Resolved)

1. **SECURITY DEFINER scenario** ✅ **RESOLVED** (commit 9ce49c5)
   - Design explicitly proposes Test 3 & 4 with SECURITY DEFINER function
   - This is a critical security boundary mentioned throughout the design
   - ~~Current Test 5 only covers `SET ROLE`, not `SECURITY DEFINER`~~
   - **Resolution**: Added Test 6a and 6b to `27_user_isolation.sql` verifying `GetOuterUserId()` correctly captures the *caller* rather than the *definer* when df.start() is called inside a SECURITY DEFINER function

   **Proposed test structure:**
   ```sql
   -- Create SECURITY DEFINER wrapper owned by superuser
   CREATE FUNCTION submit_as_definer(q TEXT) RETURNS TEXT
   LANGUAGE SQL SECURITY DEFINER
   AS $$ SELECT df.start(df.sql(q), 'secdef-test'); $$;
   GRANT EXECUTE ON FUNCTION submit_as_definer TO iso_alice;
   
   -- Alice calls it - should run as alice, NOT superuser
   SET SESSION AUTHORIZATION iso_alice;
   SELECT submit_as_definer('SELECT * FROM alice_data');  -- should succeed
   SELECT submit_as_definer('SELECT * FROM admin_table'); -- should fail
   ```

2. **Dropped role during execution** ✅ **RESOLVED** (commit 7debf88)
   - Design proposes Test 5 for this scenario
   - Important for understanding failure modes and error messages
   - ~~**Impact**: Users need to know what happens if role is dropped between submit and execution~~
   - **Resolution**: Added Test 7 to 27_user_isolation.sql verifying clear failure when role is dropped mid-execution

3. **SET ROLE membership validation** (MEDIUM PRIORITY)
   - Design states "login_role must be a member of submitted_by for SET ROLE to succeed"
   - No test verifies behavior when this invariant is violated
   - **Impact**: Rare edge case but could expose confusing error messages
   - **Recommendation**: Low priority - document as known limitation

### 📝 Desirable Additional Tests

4. **Multiple SQL nodes in sequence** (MEDIUM PRIORITY)
   - Current tests only cover single SQL nodes
   - Should verify that all nodes in a sequence run with correct user
   - **Test**: `df.start(df.sql('...') ~> df.sql('...') ~> df.sql('...'))`

5. **Complex graph structures** (MEDIUM PRIORITY)
   - No tests with conditionals (df.if), loops (df.loop), or parallel (df.join)
   - Should verify user isolation works in nested/complex graphs
   - **Test**: `df.start(df.if(condition, user_table_query, other_query))`

6. **Vars and user isolation** (LOW PRIORITY)
   - Design acknowledges df.vars is shared across users (future work)
   - No test demonstrating this limitation
   - **Test**: Alice sets var, Bob reads it (should succeed, documenting current behavior)

7. **Connection failure scenarios** (LOW PRIORITY)
   - No test for when connection to login_role fails at execution time
   - **Test**: Submit as valid user, revoke LOGIN, attempt execution

---

## 3. Implementation vs Design Alignment

### ✅ Matches Design

The implementation correctly follows the design in:

1. **Schema changes** (`src/lib.rs`)
   - ✅ Added `submitted_by REGROLE` and `login_role REGROLE` to both tables
   - ✅ Columns nullable on df.nodes, NOT NULL on df.instances
   - ✅ Column comments present and accurate

2. **Identity capture** (`src/dsl.rs`)
   - ✅ Uses `GetSessionUserId()` and `GetOuterUserId()` correctly
   - ✅ Captures OIDs and casts to `::oid::regrole` in SQL
   - ✅ Only captures in `df.start()`, not in DSL functions
   - ✅ Propagates to all nodes via recursive `link_nodes()`

3. **Type changes** (`src/types.rs`)
   - ✅ `FunctionNode` gains `submitted_by` and `login_role` fields
   - ✅ `Durofut` unchanged (identity not needed for node creation)
   - ✅ `connect_as_user()` function correctly implements connect + SET ROLE
   - ✅ Quote escaping for role names (`replace('"', "\"\"")`)

4. **Activity changes** (`src/activities/execute_sql.rs`, `load_function_graph.rs`)
   - ✅ Input structure uses JSON with query + submitted_by + login_role
   - ✅ Creates single connection per execution (not from pool)
   - ✅ Connection closed when dropped (not returned to pool)
   - ✅ Loads submitted_by and login_role in graph query

5. **Orchestration** (`src/orchestrations/execute_function_graph.rs`)
   - ✅ Deterministic: packages stable data from loaded graph
   - ✅ Passes JSON input to execute_sql activity

6. **Registry** (`src/registry.rs`)
   - ✅ Signature changed from `query: String` to `input_json: String`

7. **Worker logging** (`src/worker.rs`)
   - ✅ Filters noisy sqlx pgpass warnings

### ⚠️ Minor Deviations (Acceptable)

1. **Test 5 naming** ✅ **RESOLVED**
   - Design calls the dropped-role test "Test 5"
   - Implementation has SET ROLE test as "Test 5"
   - **Resolution**: Dropped-role test added as Test 7 in 27_user_isolation.sql
   - **Impact**: Minor - naming is flexible

2. **E2E runner flexibility**
   - Design says "Docker E2E runner changes are deferred"
   - Implementation only updates local runner
   - **Status**: Acceptable - matches design explicitly

---

## 4. Code Quality Assessment

### ✅ Strengths

1. **No code duplication in core logic**
   - Single `connect_as_user()` function reused
   - Identity capture centralized in df.start()
   - Activity input parsing consistent

2. **Good error messages with context**
   - `connect_as_user()` includes both login_role and effective_role in errors
   - Tracing shows which user is executing SQL
   - Clear JSON parse errors

3. **Type safety**
   - Using REGROLE ensures OIDs resolve to valid roles or error early
   - Rust types enforce not-null constraints

4. **Consistent naming**
   - `submitted_by` and `login_role` used everywhere
   - Clear distinction between the two identities

### ⚠️ Minor Issues

1. **Unused `_pool` parameter** (LOW PRIORITY)
   - `execute_sql::execute()` receives `_pool: Arc<PgPool>` but doesn't use it
   - Prefixed with `_` to silence warning, still passed from registry
   - **Why it exists**: Connection used to come from pool, now we create per-user connections
   - **Options**: 
     - Keep it (maintains signature consistency with other activities)
     - Remove it (cleaner but changes activity signature)
   - **Recommendation**: Keep it for now - activity signature consistency is valuable

2. **Test code duplication** (LOW PRIORITY)
   - Each test (1-5) repeats: CREATE TEMP TABLE, INSERT, wait loop, status check, DROP
   - ~15 lines duplicated 5 times
   - **Impact**: Maintenance burden if wait pattern changes
   - **Recommendation**: Extract to PL/pgSQL helper function `test_wait_for(instance_id, expected_status, test_name)`

3. **Port detection heuristic** (LOW PRIORITY)
   - `get_port()` checks for ".pgrx" in PGDATA to decide between 28817 and 5432
   - Fragile if directory structure changes
   - **Recommendation**: Accept as reasonable heuristic, or make more explicit with dedicated env var

4. **No validation that login_role has LOGIN** (MEDIUM PRIORITY)
   - Design assumes `GetSessionUserId()` always returns a LOGIN role
   - No explicit validation in Rust code
   - If somehow violated, connection will fail with unclear error from libpq
   - **Recommendation**: Low risk (PostgreSQL guarantees session user has LOGIN), but could add defensive check

### ✅ No Dead Code Identified

- All new functions are used
- No commented-out code blocks
- No unreachable branches

---

## 5. Connection Management Review

### ✅ Correctness

The per-user connection approach is **correct and properly implemented**:

1. **Single connection per SQL node**
   - Creates `PgConnection` (not from pool) via `connect_as_user()`
   - Connection dropped after SQL execution
   - No connection leak risk

2. **Proper authentication flow**
   - Connect as `login_role` (has LOGIN privilege)
   - Execute `SET ROLE submitted_by` (correct effective privileges)
   - Skip SET ROLE if both are the same (optimization)

3. **Isolation safety**
   - Each SQL node gets a fresh connection with correct user identity
   - No cross-contamination between different users' SQL nodes
   - `df.in_workflow = true` set to prevent variable mutations during execution (does not yet prevent recursive `df.start()` — potential future improvement)

### ⚠️ Performance Considerations

1. **Connection overhead** (ACKNOWLEDGED IN DESIGN)
   - Each SQL node opens a new connection: O(nodes) overhead
   - For a graph with 10 SQL nodes, that's 10 connection establishments
   - **Impact**: Latency (~5-50ms per connection depending on auth method)
   - **Mitigation**: Design explicitly proposes connection caching as future work
   - **Status**: Acceptable for MVP - correctness over performance

2. **Proposed optimization** (IN DESIGN DOCUMENT)
   - Cache connections keyed by `(instance_id, login_role, submitted_by)`
   - All nodes in an instance share the same identity
   - Reduce from O(nodes) to O(instances)
   - **Recommendation**: Track as follow-up work, not blocking

### 🔄 Alternative Considered in Design

Design mentions "SPI-based execution" as future work:
- Use `SetUserIdAndSecContext()` to switch effective user within the worker process
- No new connection needed
- Removes pg_hba.conf trust requirement
- **Status**: Deferred (good decision - connection approach is simpler and safer for MVP)

---

## 6. Security Analysis

### ✅ Security Properties Achieved

1. **Privilege isolation works**
   - Alice cannot access Bob's tables ✅
   - Bob cannot access Alice's tables ✅
   - SQL runs with submitter's privileges, not worker's ✅

2. **Correct role tracking**
   - `GetOuterUserId()` captures effective role outside SECURITY DEFINER
   - `GetSessionUserId()` captures authenticated identity
   - Both propagated to all nodes in the graph ✅

3. **No privilege escalation path** (based on implementation)
   - Non-superuser cannot gain superuser privileges via durable functions
   - Worker connects as the actual user, not impersonating ✅

4. **SET ROLE with group roles**
   - Correctly handles non-LOGIN roles as effective user
   - Connects as session user, SET ROLE to group ✅

### ❌ Security Gaps (Acknowledged in Design)

1. **HTTP activity not isolated** (HIGH PRIORITY)
   - HTTP requests run with background worker's privileges
   - No user identity passed to execute_http activity
   - **Risk**: SSRF attacks, privilege confusion
   - **Impact**: User A could potentially access internal endpoints that should be restricted
   - **Recommendation**: Track as high-priority follow-up - HTTP is a significant attack surface
   - **Design status**: Explicitly listed as "Future Work"

2. **df.vars shared across users** (MEDIUM PRIORITY)
   - All users see all variables
   - No row-level security
   - **Risk**: Information disclosure between users
   - **Impact**: Secrets or sensitive config visible to all users with df.vars access
   - **Recommendation**: Add to future work plan, document in USER_GUIDE.md
   - **Design status**: Explicitly listed as "Future Work"
   - **Documentation**: ✅ Added to USER_GUIDE.md "Current Limitations" (commit 661a30e)

3. **Cross-instance visibility** (MEDIUM PRIORITY)
   - Any user with SELECT on df.instances can see all instances
   - submitted_by column visible but no RLS enforcement
   - **Risk**: Users can see what other users are running
   - **Impact**: Privacy/information disclosure (though not direct privilege escalation)
   - **Recommendation**: RLS on df.instances and df.nodes (future work)
   - **Design status**: Explicitly listed as "Future Work"
   - **Documentation**: ✅ Added to USER_GUIDE.md "Current Limitations" (commit 661a30e)

4. **No SECURITY DEFINER test** ✅ **RESOLVED** (commit 9ce49c5)
   - ~~Cannot verify that GetOuterUserId() correctly identifies caller vs definer~~
   - ~~This is a critical security boundary~~
   - ~~**Risk**: If implementation is wrong, SECURITY DEFINER wrapper could leak privileges~~
   - **Resolution**: Test 6a and 6b added to 27_user_isolation.sql verifying correct behavior

### 🔒 Threat Model Alignment

Design document clearly states assumptions and scope:
- ✅ Extension installation requires superuser (documented)
- ✅ Background worker is trusted code (reasonable)
- ✅ PostgreSQL pg_hba.conf handles authentication (standard)
- ✅ Superusers' functions run with superuser privileges (expected, not a bug)
- ✅ DoS/rate limiting explicitly out of scope (acceptable for MVP)

**Overall threat model is reasonable and well-documented.**

---

## 7. Documentation Review

### ✅ Well-Documented

1. **Design document** (user-isolation.md)
   - Comprehensive architecture explanation
   - Clear rationale for design decisions
   - Explicit scope boundaries (in-scope vs out-of-scope)
   - Implementation checklist with file-by-file changes

2. **Code comments**
   - DB schema has column comments
   - connect_as_user() has purpose documented
   - execute_sql activity has header comment about user isolation

3. **Test comments**
   - Each test case labeled with purpose
   - Setup and cleanup sections clearly marked

### 📝 Documentation Gaps

1. **USER_GUIDE.md not updated** ✅ **RESOLVED** (commit 661a30e)
   - ~~No mention of user isolation behavior~~
   - **Resolution**: Added comprehensive "User Isolation & Privileges" section documenting:
     - Functions execute with submitter's privileges
     - Identity capture mechanism (login_role + submitted_by)
     - Group roles and SET ROLE behavior
     - Dropped role failure mode
     - Current limitations (shared df.vars, HTTP not isolated, cross-instance visibility)
     - Security best practices and minimal permission grants

2. **Migration guide missing** (LOW PRIORITY)
   - Design explicitly states "no first release yet, upgrade out of scope"
   - However, existing instances in df.instances will have NULL submitted_by/login_role after upgrade
   - **Impact**: Existing instances cannot be replayed after schema upgrade
   - **Recommendation**: Document that schema change requires clean slate (acceptable pre-release)

3. **API reference not updated** (LOW PRIORITY)
   - docs/api-reference.md might need update
   - **Recommendation**: Verify if API surface changed in user-visible ways

4. **Production deployment guidance** (LOW PRIORITY)
   - Docker pg_hba.conf configuration not documented
   - Design focuses on pgrx local development
   - **Recommendation**: Update docker-compose.yml or Dockerfile comments

---

## 8. Prioritized Issue List

### ✅ RESOLVED (Previously Blocking)

1. **Missing SECURITY DEFINER test** (Issue #1) ✅ **RESOLVED** (commit 9ce49c5)
   - **Severity**: Critical security property not verified
   - **Resolution**: Added Test 6a and 6b to 27_user_isolation.sql

### ✅ RESOLVED (Previously High Priority)

2. **HTTP activity not isolated** (Issue #2) ✅ **DOCUMENTED** (commit 661a30e)
   - **Severity**: Security gap (SSRF risk, privilege confusion)
   - **Resolution**: Added prominent warning in USER_GUIDE.md under "Current Limitations" section
   - **Design status**: Acknowledged as future work

3. **Missing dropped-role test** (Issue #3) ✅ **RESOLVED** (commit 7debf88)
   - **Severity**: Important failure mode not validated
   - **Resolution**: Added Test 7 to 27_user_isolation.sql

4. **USER_GUIDE.md not updated** (Issue #4) ✅ **RESOLVED** (commit 661a30e)
   - **Resolution**: Added comprehensive "User Isolation & Privileges" section

### 🟡 MEDIUM PRIORITY (Should address soon, not blocking)

5. **df.vars shared across users** (Issue #5)
   - **Severity**: Information disclosure risk
   - **Effort**: High (requires table redesign + RLS)
   - **Recommendation**: Document limitation in USER_GUIDE.md, track as future work

6. **Test code duplication** (Issue #6)
   - **Effort**: Low (1 hour to extract helper)
   - **Recommendation**: Create PL/pgSQL helper in 00_setup_playground.sql

7. **Multiple SQL nodes test** (Issue #7)
   - **Effort**: Low (30 minutes)
   - **Recommendation**: Add test variant with sequence of SQL nodes

8. **Complex graph structures test** (Issue #8)
   - **Effort**: Medium (1-2 hours for comprehensive test)
   - **Recommendation**: Test df.if, df.loop, df.join with user isolation

### 🟢 LOW PRIORITY (Nice to have, can defer)

9. **Production pg_hba.conf documentation** (Issue #9)
   - **Effort**: Low (30 minutes)
   - **Recommendation**: Add section to user-isolation.md or deployment docs

10. **Port detection heuristic** (Issue #10)
    - **Effort**: Low (refactor to explicit env var)
    - **Recommendation**: Accept current heuristic or add PGDURABLE_PORT env var

11. **Remove unused _pool parameter** (Issue #11)
    - **Effort**: Trivial (5 minutes)
    - **Recommendation**: Keep for signature consistency or remove if preferred

12. **Connection failure test** (Issue #12)
    - **Effort**: Low (1 hour)
    - **Recommendation**: Test connection failure error messages

13. **Vars isolation test** (Issue #13)
    - **Effort**: Low (30 minutes)
    - **Recommendation**: Document current behavior with test

---

## 9. Recommendations Summary

### ✅ Before Merge (All Completed)

1. ✅ **Add SECURITY DEFINER test** - Critical security property ✅ **RESOLVED** (commit 9ce49c5)
   - Validates that GetOuterUserId() works correctly across SECURITY DEFINER boundary
   - Test that alice calling superuser SECURITY DEFINER wrapper still runs as alice
   - **Resolution**: Test 6a and 6b added to 27_user_isolation.sql

2. ✅ **Update USER_GUIDE.md** - User-facing behavior change ✅ **RESOLVED** (commit 661a30e)
   - Document that functions run with submitter's privileges
   - Note that df.vars is still shared (limitation)
   - Explain what happens if role is dropped
   - **Resolution**: Comprehensive "User Isolation & Privileges" section added with all requested content

3. ✅ **Document HTTP isolation gap** - Security disclosure ✅ **RESOLVED** (commit 661a30e)
   - If not implementing HTTP isolation now, prominently document the limitation
   - Add to security model section
   - **Resolution**: Added to USER_GUIDE.md "Current Limitations" section

4. ✅ **Add dropped-role test** - Important failure mode ✅ **RESOLVED** (commit 7debf88)
   - Verify error message is clear
   - Ensure instance transitions to 'failed' status
   - **Resolution**: Test 7 added to 27_user_isolation.sql

### After Merge (Follow-up Work)

5. 🔒 **HTTP activity isolation** - Close security gap
   - Similar implementation to SQL isolation
   - Thread identity through execute_http activity

6. 🔐 **RLS on df.instances and df.nodes** - Privacy improvement
   - Users should only see their own instances
   - More complex: need to handle background worker access

7. 🚀 **Connection caching** - Performance optimization
   - Cache connections per (instance_id, login_role, submitted_by)
   - Significant performance improvement for multi-node graphs

8. 🔧 **df.vars user isolation** - Feature completeness
   - Add user_id column or separate per-user vars table
   - Apply RLS

---

## 10. Overall Assessment

**Rating: Strong Implementation with Minor Gaps**

### What Went Well ✅

- **Architecture**: Clean separation of concerns, identity captured once and propagated correctly
- **Code Quality**: No duplication, good naming, type-safe
- **Testing**: Comprehensive E2E coverage for primary scenarios
- **Documentation**: Thorough design document with clear scope
- **Security**: Core privilege isolation works correctly
- **Follow-through**: All review recommendations addressed with appropriate commits

### Previously Identified Gaps (Now Resolved) ✅

- ~~**SECURITY DEFINER test**: Critical gap, must add before merge~~ ✅ **RESOLVED** (commit 9ce49c5)
- ~~**Documentation**: USER_GUIDE.md needs update for user-facing behavior change~~ ✅ **RESOLVED** (commit 661a30e)
- ~~**Testing edge cases**: Dropped roles~~ ✅ **RESOLVED** (commit 7debf88)
- **HTTP isolation**: Acknowledged limitation, documented in USER_GUIDE.md ✅ **DOCUMENTED** (commit 661a30e)

### Remaining Work (Tracked as Future Items) 🔜

- **HTTP isolation implementation**: Significant effort, tracked as future work
- **Testing edge cases**: Complex graphs, failure modes (additional test coverage can be added over time)
- **Connection caching**: Performance optimization, not blocking
- **RLS implementation**: Privacy improvement, future enhancement

### Merge Readiness Assessment

**Recommendation: ✅ APPROVED FOR MERGE**

**Status Update (Feb 26, 2026)**: All blocking and strongly recommended items have been addressed:

1. ✅ **RESOLVED**: Add SECURITY DEFINER test (commit 9ce49c5)
2. ✅ **RESOLVED**: Update USER_GUIDE.md (commit 661a30e)
3. ✅ **RESOLVED**: Add dropped-role test (commit 7debf88)
4. ✅ **DOCUMENTED**: HTTP isolation gap (commit 661a30e)
5. **ACCEPTABLE DEFERRAL**: HTTP isolation implementation, connection caching, RLS (tracked as future work)

This is a solid implementation that significantly improves the security posture of pg_durable. The remaining items are tracked as follow-up issues and do not block the merge.

---

## Appendix: Specific Code Locations

For reference during fixes:

- **Tests**: `tests/e2e/sql/27_user_isolation.sql`
- **Identity capture**: `src/dsl.rs:530-550` (df.start function)
- **Connection**: `src/types.rs:82-127` (connect_as_user function)
- **Execution**: `src/activities/execute_sql.rs:24-70` (execute function)
- **Schema**: `src/lib.rs:64-90` (DDL for submitted_by/login_role)
- **HTTP activity**: `src/activities/execute_http.rs` (not yet isolated)
