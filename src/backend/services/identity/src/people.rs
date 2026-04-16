//! In-memory people store built from `bronze_bamboohr.employees`.
//!
//! Loaded once at startup. Builds email→person lookup and
//! supervisor→subordinates relationships. Returns recursive subordinate
//! trees on lookup, with circular dependency protection.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Raw row from `bronze_bamboohr.employees`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawEmployee {
    id: String,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    first_name: Option<String>,
    #[serde(default)]
    last_name: Option<String>,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    work_email: Option<String>,
    #[serde(default)]
    department: Option<String>,
    #[serde(default)]
    division: Option<String>,
    #[serde(default)]
    job_title: Option<String>,
    #[serde(default)]
    supervisor_email: Option<String>,
    #[serde(default)]
    supervisor: Option<String>,
}

/// Flat person record stored internally (no nested subordinates).
#[derive(Debug, Clone)]
struct PersonRecord {
    email: String,
    display_name: String,
    first_name: String,
    last_name: String,
    department: String,
    division: String,
    job_title: String,
    status: String,
    supervisor_email: Option<String>,
    supervisor_name: Option<String>,
    /// Direct subordinate emails (lowercased).
    direct_reports: Vec<String>,
}

/// Person returned by the API — with recursive subordinate tree.
#[derive(Debug, Clone, Serialize)]
pub struct Person {
    pub email: String,
    pub display_name: String,
    pub first_name: String,
    pub last_name: String,
    pub department: String,
    pub division: String,
    pub job_title: String,
    pub status: String,
    pub supervisor_email: Option<String>,
    pub supervisor_name: Option<String>,
    pub subordinates: Vec<Person>,
}

/// In-memory store: email (lowercased) → `PersonRecord`.
pub struct PeopleStore {
    by_email: HashMap<String, PersonRecord>,
    aliases: HashMap<String, String>,
}

impl PeopleStore {
    /// Load all active employees from ClickHouse, deduplicate by id
    /// (keep latest by `_airbyte_extracted_at`), and build relationships.
    pub async fn load(ch: &insight_clickhouse::Client) -> anyhow::Result<Self> {
        tracing::info!("loading people from bronze_bamboohr.employees");

        let sql = r"
            SELECT
                id,
                status,
                firstName,
                lastName,
                displayName,
                workEmail,
                department,
                division,
                jobTitle,
                supervisorEmail,
                supervisor
            FROM bronze_bamboohr.employees
            WHERE status = 'Active' AND workEmail != ''
            ORDER BY id, _airbyte_extracted_at DESC
        ";

        let mut cursor = ch.query(sql).fetch_bytes("JSONEachRow").map_err(|e| {
            anyhow::anyhow!("ClickHouse query failed: {e}")
        })?;

        let raw_bytes = cursor.collect().await.map_err(|e| {
            anyhow::anyhow!("ClickHouse fetch failed: {e}")
        })?;

        let mut seen_ids: HashMap<String, ()> = HashMap::new();
        let mut employees: Vec<RawEmployee> = Vec::new();

        if !raw_bytes.is_empty() {
            for line in raw_bytes.split(|&b| b == b'\n').filter(|l| !l.is_empty()) {
                let row: RawEmployee = serde_json::from_slice(line)?;
                if seen_ids.contains_key(&row.id) {
                    continue;
                }
                seen_ids.insert(row.id.clone(), ());
                employees.push(row);
            }
        }

        tracing::info!(count = employees.len(), "parsed unique active employees");

        Ok(Self::build(employees))
    }

    /// Build a store from raw JSON lines (one `RawEmployee` per line).
    /// Used for testing without ClickHouse.
    pub fn from_json_lines(data: &[u8]) -> anyhow::Result<Self> {
        let mut seen_ids: HashMap<String, ()> = HashMap::new();
        let mut employees: Vec<RawEmployee> = Vec::new();

        for line in data.split(|&b| b == b'\n').filter(|l| !l.is_empty()) {
            let row: RawEmployee = serde_json::from_slice(line)?;
            if seen_ids.contains_key(&row.id) {
                continue;
            }
            seen_ids.insert(row.id.clone(), ());
            employees.push(row);
        }

        let mut store = Self::build(employees);
        store.aliases = HashMap::new();
        Ok(store)
    }

    fn build(employees: Vec<RawEmployee>) -> Self {
        // Build flat person records
        let mut by_email: HashMap<String, PersonRecord> = HashMap::new();
        for emp in &employees {
            let email = emp.work_email.as_deref().unwrap_or_default();
            if email.is_empty() {
                continue;
            }
            let key = email.to_lowercase();
            by_email.insert(key, PersonRecord {
                email: email.to_owned(),
                display_name: emp.display_name.clone().unwrap_or_default(),
                first_name: emp.first_name.clone().unwrap_or_default(),
                last_name: emp.last_name.clone().unwrap_or_default(),
                department: emp.department.clone().unwrap_or_default(),
                division: emp.division.clone().unwrap_or_default(),
                job_title: emp.job_title.clone().unwrap_or_default(),
                status: emp.status.clone().unwrap_or_default(),
                supervisor_email: emp.supervisor_email.clone(),
                supervisor_name: emp.supervisor.clone(),
                direct_reports: Vec::new(),
            });
        }

        // Build direct_reports: for each person, register them under their supervisor
        for emp in &employees {
            if let Some(ref sup_email) = emp.supervisor_email {
                let sup_key = sup_email.to_lowercase();
                let email = emp.work_email.as_deref().unwrap_or_default();
                if email.is_empty() {
                    continue;
                }
                if let Some(supervisor) = by_email.get_mut(&sup_key) {
                    supervisor.direct_reports.push(email.to_lowercase());
                }
            }
        }

        let mut aliases = HashMap::new();
        aliases.insert(
            "test@vz.com".to_owned(),
            "oleksii.shponarskyi@virtuozzo.com".to_owned(),
        );

        Self { by_email, aliases }
    }

    /// Look up a person by email, returning the full recursive subordinate tree.
    pub fn get_by_email(&self, email: &str) -> Option<Person> {
        let key = email.to_lowercase();
        let resolved = self.aliases.get(&key).unwrap_or(&key);
        let record = self.by_email.get(resolved)?;
        let mut visited = HashSet::new();
        Some(self.build_tree(record, &mut visited))
    }

    /// Recursively build a `Person` with nested subordinates.
    /// `visited` prevents infinite loops from circular supervisor references.
    fn build_tree(&self, record: &PersonRecord, visited: &mut HashSet<String>) -> Person {
        let key = record.email.to_lowercase();
        visited.insert(key);

        let subordinates = record
            .direct_reports
            .iter()
            .filter_map(|sub_email| {
                if visited.contains(sub_email) {
                    return None; // break cycle
                }
                let sub_record = self.by_email.get(sub_email)?;
                Some(self.build_tree(sub_record, visited))
            })
            .collect();

        Person {
            email: record.email.clone(),
            display_name: record.display_name.clone(),
            first_name: record.first_name.clone(),
            last_name: record.last_name.clone(),
            department: record.department.clone(),
            division: record.division.clone(),
            job_title: record.job_title.clone(),
            status: record.status.clone(),
            supervisor_email: record.supervisor_email.clone(),
            supervisor_name: record.supervisor_name.clone(),
            subordinates,
        }
    }

    pub fn len(&self) -> usize {
        self.by_email.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_data() -> &'static [u8] {
        br#"{"id":"1","status":"Active","firstName":"Alice","lastName":"Smith","displayName":"Alice Smith","workEmail":"alice@example.com","department":"Engineering","division":"R&D","jobTitle":"Staff Engineer","supervisorEmail":"bob@example.com","supervisor":"Jones, Bob"}
{"id":"2","status":"Active","firstName":"Bob","lastName":"Jones","displayName":"Bob Jones","workEmail":"bob@example.com","department":"Engineering","division":"R&D","jobTitle":"Engineering Manager","supervisorEmail":"carol@example.com","supervisor":"Lee, Carol"}
{"id":"3","status":"Active","firstName":"Carol","lastName":"Lee","displayName":"Carol Lee","workEmail":"carol@example.com","department":"Engineering","division":"R&D","jobTitle":"VP Engineering","supervisorEmail":null,"supervisor":null}
{"id":"4","status":"Active","firstName":"Dave","lastName":"Ng","displayName":"Dave Ng","workEmail":"dave@example.com","department":"Engineering","division":"R&D","jobTitle":"Senior Engineer","supervisorEmail":"bob@example.com","supervisor":"Jones, Bob"}"#
    }

    #[test]
    fn loads_all_employees() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        assert_eq!(store.len(), 4);
    }

    #[test]
    fn lookup_by_email() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        let alice = store.get_by_email("alice@example.com").unwrap();
        assert_eq!(alice.display_name, "Alice Smith");
        assert_eq!(alice.department, "Engineering");
        assert_eq!(alice.job_title, "Staff Engineer");
    }

    #[test]
    fn lookup_case_insensitive() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        assert!(store.get_by_email("Alice@Example.COM").is_some());
    }

    #[test]
    fn lookup_not_found() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        assert!(store.get_by_email("nobody@example.com").is_none());
    }

    #[test]
    fn supervisor_has_subordinates() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        let bob = store.get_by_email("bob@example.com").unwrap();
        assert_eq!(bob.subordinates.len(), 2);

        let sub_emails: Vec<&str> = bob.subordinates.iter().map(|s| s.email.as_str()).collect();
        assert!(sub_emails.contains(&"alice@example.com"));
        assert!(sub_emails.contains(&"dave@example.com"));
    }

    #[test]
    fn leaf_employee_has_no_subordinates() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        let alice = store.get_by_email("alice@example.com").unwrap();
        assert!(alice.subordinates.is_empty());
    }

    #[test]
    fn supervisor_info_populated() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        let alice = store.get_by_email("alice@example.com").unwrap();
        assert_eq!(alice.supervisor_email.as_deref(), Some("bob@example.com"));
        assert_eq!(alice.supervisor_name.as_deref(), Some("Jones, Bob"));
    }

    #[test]
    fn top_level_has_no_supervisor() {
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        let carol = store.get_by_email("carol@example.com").unwrap();
        assert!(carol.supervisor_email.is_none());
        assert!(carol.supervisor_name.is_none());
    }

    #[test]
    fn recursive_tree() {
        // Carol → Bob → Alice, Dave
        let store = PeopleStore::from_json_lines(test_data()).unwrap();
        let carol = store.get_by_email("carol@example.com").unwrap();

        assert_eq!(carol.subordinates.len(), 1);
        let bob = &carol.subordinates[0];
        assert_eq!(bob.email, "bob@example.com");
        assert_eq!(bob.subordinates.len(), 2);

        let nested_emails: Vec<&str> = bob.subordinates.iter().map(|s| s.email.as_str()).collect();
        assert!(nested_emails.contains(&"alice@example.com"));
        assert!(nested_emails.contains(&"dave@example.com"));

        // Leaves have no subordinates
        for leaf in &bob.subordinates {
            assert!(leaf.subordinates.is_empty());
        }
    }

    #[test]
    fn circular_dependency_safe() {
        // A reports to B, B reports to A — cycle
        let data = br#"{"id":"1","status":"Active","firstName":"A","lastName":"A","displayName":"A","workEmail":"a@example.com","department":"Eng","division":"R&D","jobTitle":"Eng","supervisorEmail":"b@example.com","supervisor":"B"}
{"id":"2","status":"Active","firstName":"B","lastName":"B","displayName":"B","workEmail":"b@example.com","department":"Eng","division":"R&D","jobTitle":"Eng","supervisorEmail":"a@example.com","supervisor":"A"}"#;
        let store = PeopleStore::from_json_lines(data).unwrap();

        let a = store.get_by_email("a@example.com").unwrap();
        // A has B as subordinate, but B should NOT have A again (cycle broken)
        assert_eq!(a.subordinates.len(), 1);
        assert_eq!(a.subordinates[0].email, "b@example.com");
        assert!(a.subordinates[0].subordinates.is_empty()); // cycle cut

        let b = store.get_by_email("b@example.com").unwrap();
        assert_eq!(b.subordinates.len(), 1);
        assert_eq!(b.subordinates[0].email, "a@example.com");
        assert!(b.subordinates[0].subordinates.is_empty()); // cycle cut
    }

    #[test]
    fn deduplicates_by_id() {
        let data = br#"{"id":"1","status":"Active","firstName":"Alice","lastName":"Smith","displayName":"Alice Smith","workEmail":"alice@example.com","department":"Eng","division":"R&D","jobTitle":"Engineer","supervisorEmail":null,"supervisor":null}
{"id":"1","status":"Active","firstName":"Alice","lastName":"Smith-Updated","displayName":"Alice Smith-Updated","workEmail":"alice@example.com","department":"Eng","division":"R&D","jobTitle":"Staff Engineer","supervisorEmail":null,"supervisor":null}"#;
        let store = PeopleStore::from_json_lines(data).unwrap();
        assert_eq!(store.len(), 1);
        let alice = store.get_by_email("alice@example.com").unwrap();
        assert_eq!(alice.last_name, "Smith");
    }

    #[test]
    fn empty_data() {
        let store = PeopleStore::from_json_lines(b"").unwrap();
        assert_eq!(store.len(), 0);
    }

    #[test]
    fn skips_empty_email() {
        let data = br#"{"id":"1","status":"Active","firstName":"Ghost","lastName":"User","displayName":"Ghost","workEmail":"","department":"Eng","division":"R&D","jobTitle":"","supervisorEmail":null,"supervisor":null}"#;
        let store = PeopleStore::from_json_lines(data).unwrap();
        assert_eq!(store.len(), 0);
    }
}
