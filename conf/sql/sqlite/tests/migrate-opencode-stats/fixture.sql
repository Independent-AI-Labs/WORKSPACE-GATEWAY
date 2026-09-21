-- SQLite source fixture for the migrate-opencode-stats rehearsal (FR-5.1).
-- Loaded into a throwaway .backup copy; never touches the live database.
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, version TEXT NOT NULL, agent TEXT);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);
INSERT INTO session VALUES ('s1','p1',NULL,'1.17.11','build');
INSERT INTO message VALUES ('msg_a01','s1',1787917493000,'{"role":"assistant","agent":"build","modelID":"k3","providerID":"workspace-gw-kimi","cost":0.5,"tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":7,"write":3}},"time":{"created":1787917493000,"completed":1787917494500}}');
INSERT INTO part VALUES ('prt_a01a','msg_a01','s1',1787917493001,'{"type":"reasoning","text":"think"}');
INSERT INTO part VALUES ('prt_a01b','msg_a01','s1',1787917493002,'{"type":"text","text":"answer"}');
INSERT INTO message VALUES ('msg_a02','s1',1787917494000,'{"role":"assistant","agent":"plan","modelID":"/zip/MiniCPM5-1B-Q8_0.gguf","providerID":"workspace-gw-llamafile","cost":0,"tokens":{"input":1,"output":2,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1787917494000,"completed":1787917494200},"error":{"name":"MessageAbortedError","message":"Aborted"}}');
INSERT INTO message VALUES ('msg_a03','s1',1787917493000,'{"role":"assistant","agent":"build","modelID":"k3","providerID":"workspace-gw-kimi","cost":0.5,"tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":7,"write":3}},"time":{"created":1787917493000,"completed":1787917494500}}');
INSERT INTO part VALUES ('prt_a03a','msg_a03','s1',1787917493011,'{"type":"reasoning","text":"think"}');
INSERT INTO part VALUES ('prt_a03b','msg_a03','s1',1787917493012,'{"type":"text","text":"answer"}');
INSERT INTO message VALUES ('msg_u01','s1',1787917492000,'{"role":"user","time":{"created":1787917492000}}');
INSERT INTO part VALUES ('prt_u01a','msg_u01','s1',1787917492001,'{"type":"text","text":"hello"}');
INSERT INTO part VALUES ('prt_a01c','msg_a01','s1',1787917493003,'{"type":"tool","text":"The user rejected permission to use this specific tool call: bash"}');
INSERT INTO part VALUES ('prt_a01d','msg_a01','s1',1787917493004,'{"type":"tool","text":"BLOCKED: bash rm -rf / by deny rule"}');
INSERT INTO message VALUES ('msg_o01','ghost',1787917495000,'{"role":"assistant","agent":"build","modelID":"glm-5.3","providerID":"zai-coding-plan","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1787917495000}}');
INSERT INTO message VALUES ('msg_b01','s1',1787917495000,'{"role":"assistant","agent":"build","modelID":"glm-5.3","providerID":"zai-coding-plan","cost":0,"tokens":{"input":1000000,"output":300000,"reasoning":200000,"cache":{"read":0,"write":0}},"time":{"created":1787917495000}}');
INSERT INTO message VALUES ('msg_b02','s1',1787917496000,'{"role":"assistant","agent":"build","modelID":"zai.glm-5","providerID":"amazon-bedrock","cost":0,"tokens":{"input":1000000,"output":1000000,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1787917496000,"completed":1787917496100}}');
INSERT INTO message VALUES ('msg_b03','s1',1787917497000,'{"role":"assistant","agent":"build","modelID":"no-such-model","providerID":"no-such-provider","cost":0,"tokens":{"input":10,"output":20,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1787917497000},"error":{"name":"APIError","message":"Connection reset by server"}}');
