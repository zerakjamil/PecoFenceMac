use pecofence_core::*;
use serde_json::{Value, json};
use std::{
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

fn main() {
    let outcome = run();
    match outcome {
        Ok(state) => println!("{}", json!({"ok":true,"state":state})),
        Err(message) => {
            println!("{}", json!({"ok":false,"error":message}));
            std::process::exit(1);
        }
    }
}

fn run() -> Result<Value, String> {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--help") {
        return Ok(
            json!({"usage":"pecofence-mac-cli [--config-dir PATH] < request.json",
            "operations":["state","sync","create","update","reorder","delete","assign","remove","rule-add","rule-delete","apply-rules","snapshot-save","snapshot-restore","settings","export","import"],
            "example":{"op":"create","title":"Projects"}}),
        );
    }
    let dir = if args.len() == 3 && args[1] == "--config-dir" {
        PathBuf::from(&args[2])
    } else if args.len() == 1 {
        PathBuf::from(std::env::var("PECOFENCE_CONFIG_DIR").unwrap_or_else(|_| {
            format!(
                "{}/Library/Application Support/PecoFence",
                std::env::var("HOME").unwrap_or_default()
            )
        }))
    } else {
        return Err("Usage: pecofence-mac-cli [--config-dir PATH]".into());
    };
    // GUI and terminal clients share one config; serialize read-modify-write across processes.
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join("config.lock"))
        .map_err(|e| e.to_string())?;
    lock.lock().map_err(|e| e.to_string())?;
    let mut input = String::new();
    io::stdin()
        .take(4 * 1024 * 1024)
        .read_to_string(&mut input)
        .map_err(|e| e.to_string())?;
    let req: Value = serde_json::from_str(&input).map_err(|e| e.to_string())?;
    let store = ConfigStore::new(dir);
    let (loaded, quarantined) = store.load_reporting();
    let fresh = matches!(&loaded, LoadOutcome::Fresh(_));
    if fresh && quarantined.is_some() {
        return Err("Configuration unreadable; preserved beside config.json. Restore a backup before retrying.".into());
    }
    let mut cfg = loaded.into_config();
    if cfg.layouts.is_empty() {
        initialize(&mut cfg);
    }
    let before = serde_json::to_value(&cfg).map_err(|e| e.to_string())?;
    operate(&mut cfg, &req)?;
    if fresh || before != serde_json::to_value(&cfg).map_err(|e| e.to_string())? {
        store.save(&cfg).map_err(|e| e.to_string())?;
    }
    let mut state = presentation(&cfg);
    state["configPath"] = json!(store.primary_path());
    if let Some(path) = quarantined {
        state["recoveryWarning"] = json!(format!(
            "Recovered backup. Unreadable config preserved at {}",
            path.display()
        ));
    }
    Ok(state)
}

fn geometry(index: usize) -> NormGeometry {
    NormGeometry {
        monitor: "main".into(),
        x: 24.0 + (index % 3) as f32 * 310.0,
        y: 30.0 + (index / 3) as f32 * 340.0,
        w: 290.0,
        h: 310.0,
        work_w: 1440.0,
        work_h: 900.0,
        anchor: Anchor::LeftTop,
    }
}

fn initialize(cfg: &mut Config) {
    cfg.settings.autostart = false;
    cfg.settings.hide_real_icons = false;
    cfg.layouts.push(Layout {
        fingerprint: vec![],
        fences: vec![
            Fence::new("Desktop", FenceKind::Inbox, geometry(0)),
            Fence::new("Projects", FenceKind::Virtual, geometry(1)),
        ],
    });
}

fn required<'a>(req: &'a Value, key: &str) -> Result<&'a str, String> {
    req[key]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| format!("Missing {key}"))
}
fn id(req: &Value, key: &str) -> Result<Uuid, String> {
    Uuid::parse_str(required(req, key)?).map_err(|e| e.to_string())
}
fn fence_mut(cfg: &mut Config, fid: Uuid) -> Result<&mut Fence, String> {
    cfg.layouts[0]
        .fences
        .iter_mut()
        .find(|f| f.id == fid)
        .ok_or_else(|| "Fence not found".into())
}
fn target(cfg: &Config, fid: Uuid) -> Result<(), String> {
    let f = cfg.layouts[0]
        .fences
        .iter()
        .find(|f| f.id == fid)
        .ok_or("Fence not found")?;
    if f.kind == FenceKind::FolderPortal {
        return Err("Folder portals cannot receive virtual assignments".into());
    }
    Ok(())
}
fn operate(cfg: &mut Config, req: &Value) -> Result<(), String> {
    match required(req, "op")? {
        "state" => {}
        "sync" => sync(cfg, required(req, "desktop")?)?,
        "create" => {
            if cfg.layouts[0].fences.len() >= pecofence_core::config_store::MAX_FENCES {
                return Err("Maximum 64 fences".into());
            }
            let mut f = Fence::new(
                required(req, "title")?,
                FenceKind::Virtual,
                geometry(cfg.layouts[0].fences.len()),
            );
            if let Some(path) = req["path"].as_str() {
                if !Path::new(path).is_dir() {
                    return Err("Portal path must be an accessible folder".into());
                }
                f.kind = FenceKind::FolderPortal;
                f.source = ItemSourceSpec::Folder {
                    path: path.into(),
                    recursive: false,
                    filter: None,
                };
            }
            cfg.layouts[0].fences.push(f);
        }
        "update" => {
            apply_geometries(cfg, req)?;
            let fid = id(req, "id")?;
            let f = fence_mut(cfg, fid)?;
            let before = f.clone();
            if let Some(title) = req["title"].as_str() {
                if title.trim().is_empty() {
                    return Err("Title cannot be empty".into());
                }
                f.title = title.into();
            }
            if let Some(v) = req["rolledUp"].as_bool() {
                f.rolled_up = v;
            }
            if let Some(v) = req["locked"].as_bool() {
                f.locked = v;
            }
            if !req["geometry"].is_null() {
                f.geometry =
                    serde_json::from_value(req["geometry"].clone()).map_err(|e| e.to_string())?;
            }
            if let Some(v) = req["view"].as_str() {
                f.view.layout = match v {
                    "icons" => ViewLayout::Icons,
                    "list" => ViewLayout::List,
                    _ => return Err("View must be icons or list".into()),
                };
            }
            if let Some(v) = req["sort"].as_str() {
                f.view.sort = match v {
                    "name" => SortMode::Name,
                    "date" => SortMode::Date,
                    "type" => SortMode::Type,
                    "manual" => SortMode::Manual,
                    _ => return Err("Unknown sort mode".into()),
                };
            }
            if before.rolled_up != f.rolled_up {
                reflow_fences(
                    &mut cfg.layouts[0].fences,
                    &before,
                    req["mainMonitor"].as_str(),
                )?;
            }
        }
        "reorder" => {
            apply_geometries(cfg, req)?;
            reorder_fence(
                &mut cfg.layouts[0].fences,
                id(req, "id")?,
                id(req, "target")?,
                req["after"].as_bool().unwrap_or(false),
            )?;
        }
        "delete" => {
            let fid = id(req, "id")?;
            let f = fence_mut(cfg, fid)?;
            if f.kind == FenceKind::Inbox {
                return Err("Desktop inbox cannot be deleted".into());
            }
            let refs = std::mem::take(&mut f.items);
            cfg.layouts[0].fences.retain(|f| f.id != fid);
            if let Some(inbox) = cfg.layouts[0]
                .fences
                .iter_mut()
                .find(|f| f.kind == FenceKind::Inbox)
            {
                inbox.items.extend(refs);
            }
            cfg.rules.list.retain(|r| r.target != Target::Fence(fid));
        }
        "assign" => {
            let fid = id(req, "fence")?;
            target(cfg, fid)?;
            let paths = req["paths"].as_array().ok_or("Missing paths array")?;
            for path in paths {
                let path = path.as_str().ok_or("Path must be string")?;
                let iid = register(cfg, Path::new(path))?;
                assign(cfg, iid, fid, AssignedBy::User);
            }
        }
        "remove" => {
            let iid = id(req, "item")?;
            if !cfg.items.contains_key(&iid) {
                return Err("Item not found".into());
            }
            let inbox = cfg.layouts[0]
                .fences
                .iter()
                .find(|f| f.kind == FenceKind::Inbox)
                .ok_or("Inbox missing")?
                .id;
            assign(cfg, iid, inbox, AssignedBy::User);
        }
        "rule-add" => {
            let fid = id(req, "fence")?;
            target(cfg, fid)?;
            let exts: Vec<String> = required(req, "extensions")?
                .split([',', ' '])
                .filter(|s| !s.is_empty())
                .map(|s| format!(".{}", s.trim_start_matches('.').to_lowercase()))
                .collect();
            if exts.is_empty() {
                return Err("Enter at least one extension".into());
            }
            cfg.rules.list.insert(
                0,
                Rule::new(
                    required(req, "name")?,
                    Target::Fence(fid),
                    vec![Cond::Ext(exts)],
                ),
            );
            apply_rules(cfg, false);
        }
        "rule-delete" => {
            let rid = id(req, "id")?;
            cfg.rules.list.retain(|r| r.id != rid);
        }
        "apply-rules" => apply_rules(cfg, true),
        "snapshot-save" => {
            if !req["fingerprint"].is_null() {
                cfg.layouts[0].fingerprint = serde_json::from_value(req["fingerprint"].clone())
                    .map_err(|e| e.to_string())?;
            }
            apply_geometries(cfg, req)?;
            cfg.snapshots.push(Snapshot {
                id: Uuid::new_v4(),
                name: required(req, "name")?.into(),
                ts: now(),
                layouts: cfg.layouts.clone(),
            });
            if cfg.snapshots.len() > MAX_SNAPSHOTS {
                cfg.snapshots.remove(0);
            }
        }
        "snapshot-restore" => {
            let sid = id(req, "id")?;
            cfg.layouts = cfg
                .snapshots
                .iter()
                .find(|s| s.id == sid)
                .ok_or("Snapshot not found")?
                .layouts
                .clone();
        }
        "settings" => {
            if let Some(theme) = req["theme"].as_str() {
                cfg.settings.theme = match theme {
                    "dark" => ThemeSetting::Dark,
                    "light" => ThemeSetting::Light,
                    "system" => ThemeSetting::FollowAppMode,
                    _ => return Err("Unknown theme".into()),
                };
            }
            if let Some(v) = req["keepUpdated"].as_bool() {
                cfg.rules.keep_updated = v;
            }
        }
        "export" => ConfigStore::export_to(cfg, Path::new(required(req, "path")?))
            .map_err(|e| e.to_string())?,
        "import" => {
            let imported = ConfigStore::parse_file(Path::new(required(req, "path")?))?;
            if imported.layouts.is_empty()
                || imported.layouts[0]
                    .fences
                    .iter()
                    .filter(|f| f.kind == FenceKind::Inbox)
                    .count()
                    != 1
            {
                return Err(
                    "Mac config must contain a layout with exactly one Desktop inbox".into(),
                );
            }
            *cfg = imported;
        }
        op => return Err(format!("Unknown operation: {op}")),
    }
    Ok(())
}

const TITLE_HEIGHT: f32 = 38.0;
const STACK_GAP: f32 = 8.0;

fn apply_geometries(cfg: &mut Config, req: &Value) -> Result<(), String> {
    if let Some(geometries) = req["geometries"].as_object() {
        for (fid, geometry) in geometries {
            let fid = Uuid::parse_str(fid).map_err(|e| e.to_string())?;
            fence_mut(cfg, fid)?.geometry =
                serde_json::from_value(geometry.clone()).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn reorder_fence(
    fences: &mut [Fence],
    source_id: Uuid,
    target_id: Uuid,
    after: bool,
) -> Result<(), String> {
    if source_id == target_id {
        return Ok(());
    }
    let source = fences
        .iter()
        .position(|f| f.id == source_id)
        .ok_or("Fence not found")?;
    let target = fences
        .iter()
        .find(|f| f.id == target_id)
        .ok_or("Target fence not found")?
        .clone();
    if fences[source].locked {
        return Err("Unlock the source fence before reordering.".into());
    }
    let mut column: Vec<usize> = fences
        .iter()
        .enumerate()
        .filter(|(_, f)| {
            f.geometry.monitor == target.geometry.monitor && horizontal_overlap(f, &target)
        })
        .map(|(i, _)| i)
        .collect();
    let top = column
        .iter()
        .map(|i| fences[*i].geometry.y)
        .fold(target.geometry.y, f32::min);
    column.retain(|i| *i != source);
    column.sort_by(|a, b| fences[*a].geometry.y.total_cmp(&fences[*b].geometry.y));
    let insertion = column
        .iter()
        .position(|i| fences[*i].id == target_id)
        .ok_or("Target column not found")?
        + usize::from(after);
    column.insert(insertion, source);
    let mut y = top;
    for index in column {
        let fence = &mut fences[index];
        if fence.locked
            && ((fence.geometry.y - y).abs() > 0.5
                || (fence.geometry.x - target.geometry.x).abs() > 0.5)
        {
            return Err(format!(
                "Unlock {} before reordering this stack.",
                fence.title
            ));
        }
        if y + visible_height(fence) > target.geometry.work_h
            || target.geometry.x + fence.geometry.w > target.geometry.work_w
        {
            return Err(
                "Not enough screen space for this stack. Collapse or resize a fence first.".into(),
            );
        }
        fence.geometry.y = y;
        fence.geometry.x = target.geometry.x;
        fence.geometry.monitor = target.geometry.monitor.clone();
        fence.geometry.work_h = target.geometry.work_h;
        fence.geometry.work_w = target.geometry.work_w;
        y += visible_height(fence) + STACK_GAP;
    }
    Ok(())
}

fn visible_height(fence: &Fence) -> f32 {
    if fence.rolled_up {
        TITLE_HEIGHT
    } else {
        fence.geometry.h.max(160.0)
    }
}

fn horizontal_overlap(left: &Fence, right: &Fence) -> bool {
    left.geometry.x < right.geometry.x + right.geometry.w
        && right.geometry.x < left.geometry.x + left.geometry.w
}

fn reflow_fences(
    fences: &mut [Fence],
    before: &Fence,
    main_monitor: Option<&str>,
) -> Result<(), String> {
    let source = fences
        .iter()
        .find(|f| f.id == before.id)
        .ok_or("Fence not found")?
        .clone();
    let resolve_monitor = |f: &Fence| {
        if f.geometry.monitor == "main" {
            main_monitor.unwrap_or("main").to_string()
        } else {
            f.geometry.monitor.clone()
        }
    };
    let monitor = resolve_monitor(&source);
    let old_bottom = before.geometry.y + visible_height(before);
    let delta = visible_height(&source) - visible_height(before);
    let work_h = source.geometry.work_h;
    if source.geometry.y + visible_height(&source) > work_h {
        return Err(
            "Not enough screen space to expand this fence. Move it higher or reduce its height."
                .into(),
        );
    }
    let mut candidates: Vec<usize> = fences
        .iter()
        .enumerate()
        .filter(|(_, f)| {
            f.id != source.id && resolve_monitor(f) == monitor && f.geometry.y >= old_bottom - 1.0
        })
        .map(|(index, _)| index)
        .collect();
    candidates.sort_by(|a, b| fences[*a].geometry.y.total_cmp(&fences[*b].geometry.y));
    let mut placed = vec![(before.clone(), source)];
    for index in candidates {
        let original = fences[index].clone();
        let relevant: Vec<_> = placed
            .iter()
            .filter(|(_, moved)| horizontal_overlap(moved, &original))
            .collect();
        let floor = relevant
            .iter()
            .map(|(_, moved)| moved.geometry.y + visible_height(moved) + STACK_GAP)
            .fold(f32::NEG_INFINITY, f32::max);
        let affected: Vec<_> = relevant
            .iter()
            .filter(|(old, moved)| {
                (old.geometry.y + visible_height(old) - moved.geometry.y - visible_height(moved))
                    .abs()
                    > 0.5
            })
            .collect();
        let new_y = if delta > 0.0 {
            let pushed_floor = affected
                .iter()
                .map(|(_, moved)| moved.geometry.y + visible_height(moved) + STACK_GAP)
                .fold(f32::NEG_INFINITY, f32::max);
            if pushed_floor > original.geometry.y {
                pushed_floor.max(floor)
            } else {
                original.geometry.y
            }
        } else {
            // Close only the contiguous stack, keeping deliberately spaced fences in place.
            let connected_y = affected
                .iter()
                .filter(|(old, _)| {
                    (original.geometry.y - old.geometry.y - visible_height(old) - STACK_GAP).abs()
                        <= 2.0
                })
                .map(|(old, moved)| {
                    original.geometry.y + moved.geometry.y + visible_height(moved)
                        - old.geometry.y
                        - visible_height(old)
                })
                .reduce(f32::max);
            if let Some(y) = connected_y.filter(|_| !original.locked) {
                y.max(floor)
            } else {
                original.geometry.y
            }
        };
        if new_y > original.geometry.y + 0.5 && original.locked {
            return Err(format!(
                "Cannot expand: {} is locked below this fence. Unlock or move it first.",
                original.title
            ));
        }
        if new_y > original.geometry.y + 0.5 && new_y + visible_height(&original) > work_h {
            return Err("Not enough screen space for the expanded stack. Collapse a lower fence or reduce its height.".into());
        }
        if (new_y - original.geometry.y).abs() > 0.5 {
            fences[index].geometry.y = new_y;
            fences[index].geometry.work_h = work_h;
        }
        placed.push((original, fences[index].clone()));
    }
    Ok(())
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn register(cfg: &mut Config, path: &Path) -> Result<Uuid, String> {
    let absolute = fs::canonicalize(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let path = absolute
        .to_str()
        .ok_or("Non-UTF8 paths are unsupported")?
        .to_string();
    // macOS volumes can be case-sensitive. Keep POSIX paths exactly as resolved.
    let key = ItemKey::Path(path.clone());
    let existing = cfg.items.values().find(|i| i.key == key).map(|i| i.id);
    let iid = existing.unwrap_or_else(Uuid::new_v4);
    let meta = fs::metadata(&absolute).map_err(|e| e.to_string())?;
    let old = cfg.items.get(&iid);
    cfg.items.insert(
        iid,
        Item {
            id: iid,
            key,
            origin: Origin::UserDesktop,
            display_name: absolute
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into(),
            file_id: None,
            mtime: meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0),
            is_folder: meta.is_dir(),
            attrs: 0,
            icon_key: IconKey::ByContent { path, mtime: 0 },
            orphaned_since: None,
            size: meta.len(),
            open_count: old.map(|i| i.open_count).unwrap_or(0),
            last_opened: old.and_then(|i| i.last_opened),
        },
    );
    Ok(iid)
}
fn assign(cfg: &mut Config, iid: Uuid, fid: Uuid, by: AssignedBy) {
    for f in &mut cfg.layouts[0].fences {
        f.items.retain(|r| r.item_id != iid);
    }
    if let Some(f) = cfg.layouts[0].fences.iter_mut().find(|f| f.id == fid) {
        f.items.push(ItemRef {
            item_id: iid,
            manual_index: None,
            assigned_by: by,
        });
    }
}
fn sync(cfg: &mut Config, desktop: &str) -> Result<(), String> {
    let entries=fs::read_dir(desktop).map_err(|e|format!("Cannot read Desktop: {e}. Allow Desktop access in System Settings → Privacy & Security → Files and Folders."))?;
    let inbox = cfg.layouts[0]
        .fences
        .iter()
        .find(|f| f.kind == FenceKind::Inbox)
        .ok_or("Inbox missing")?
        .id;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let iid = register(cfg, &entry.path())?;
        if !cfg.layouts[0].fences.iter().any(|f| f.contains_item(iid)) {
            assign(cfg, iid, inbox, AssignedBy::Migration);
        }
    }
    let missing: Vec<Uuid> = cfg
        .items
        .values()
        .filter(|i| i.key.as_path().is_some_and(|p| !Path::new(p).exists()))
        .map(|i| i.id)
        .collect();
    for iid in missing {
        cfg.items.remove(&iid);
        for f in &mut cfg.layouts[0].fences {
            f.items.retain(|r| r.item_id != iid);
        }
    }
    cfg.settings.desktop_path = Some(desktop.into());
    if cfg.rules.keep_updated {
        apply_rules(cfg, false);
    }
    Ok(())
}
fn apply_rules(cfg: &mut Config, include_manual: bool) {
    let inbox = cfg.layouts[0]
        .fences
        .iter()
        .find(|f| f.kind == FenceKind::Inbox)
        .map(|f| f.id);
    let items: Vec<Item> = cfg.items.values().cloned().collect();
    for item in items {
        if !include_manual
            && cfg.layouts[0]
                .fences
                .iter()
                .flat_map(|f| &f.items)
                .any(|r| r.item_id == item.id && r.assigned_by == AssignedBy::User)
        {
            continue;
        }
        let facts = ItemFacts {
            file_name: item.display_name.clone(),
            is_folder: item.is_folder,
            size_bytes: item.size,
            ..Default::default()
        };
        let (to, by) = match cfg.rules.evaluate(&facts) {
            Decision::Route { target, rule } => (target, AssignedBy::Rule(rule)),
            Decision::Default(target) => (target, AssignedBy::Migration),
            Decision::Skip => continue,
        };
        let fid = match to {
            Target::Inbox => inbox,
            Target::Fence(fid) => Some(fid),
        };
        if let Some(fid) = fid.filter(|fid| target(cfg, *fid).is_ok()) {
            let unchanged = cfg.layouts[0].fences.iter().any(|f| {
                f.id == fid
                    && f.items
                        .iter()
                        .any(|r| r.item_id == item.id && r.assigned_by == by)
            });
            if !unchanged {
                assign(cfg, item.id, fid, by);
            }
        }
    }
}
fn presentation(cfg: &Config) -> Value {
    let fences:Vec<Value>=cfg.layouts[0].fences.iter().map(|f|{
        let items:Vec<Value>=f.items.iter().filter_map(|r|cfg.items.get(&r.item_id)).map(|i|json!({"id":i.id,"path":i.key.as_path(),"name":i.display_name,"isFolder":i.is_folder,"mtime":i.mtime,"size":i.size})).collect();
        json!({"id":f.id,"title":f.title,"kind":f.kind,"source":f.source,"geometry":f.geometry,"rolledUp":f.rolled_up,"locked":f.locked,"view":f.view.layout,"sort":f.view.sort,"items":items})
    }).collect();
    json!({"fences":fences,"rules":cfg.rules.list,"snapshots":cfg.snapshots.iter().map(|s|json!({"id":s.id,"name":s.name,"displays":s.layouts.first().map(|l|l.fingerprint.iter().map(|m|m.device_path.clone()).collect::<Vec<_>>()).unwrap_or_default()})).collect::<Vec<_>>(),
        "theme":match cfg.settings.theme {ThemeSetting::Dark=>"dark",ThemeSetting::Light=>"light",_=>"system"},"keepUpdated":cfg.rules.keep_updated})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn panel(title: &str, x: f32, y: f32, height: f32, rolled: bool) -> Fence {
        let mut f = Fence::new(title, FenceKind::Virtual, geometry(0));
        f.geometry.x = x;
        f.geometry.y = y;
        f.geometry.h = height;
        f.geometry.work_h = 1000.0;
        f.rolled_up = rolled;
        f
    }

    #[test]
    fn expansion_cascades_and_collapse_restores_stack() {
        let source = panel("Top", 20.0, 20.0, 300.0, true);
        let lower = panel("Middle", 20.0, 66.0, 200.0, false);
        let bottom = panel("Bottom", 20.0, 274.0, 180.0, false);
        let mut fences = vec![source.clone(), lower, bottom];
        fences[0].rolled_up = false;
        reflow_fences(&mut fences, &source, None).unwrap();
        assert_eq!(fences[1].geometry.y, 328.0);
        assert_eq!(fences[2].geometry.y, 536.0);
        let expanded = fences[0].clone();
        fences[0].rolled_up = true;
        reflow_fences(&mut fences, &expanded, None).unwrap();
        assert_eq!(fences[1].geometry.y, 66.0);
        assert_eq!(fences[2].geometry.y, 274.0);
    }

    #[test]
    fn expansion_leaves_unrelated_columns_and_monitors_alone() {
        let source = panel("Top", 20.0, 20.0, 300.0, true);
        let side = panel("Side", 500.0, 66.0, 200.0, false);
        let mut other_screen = panel("External", 20.0, 66.0, 200.0, false);
        other_screen.geometry.monitor = "external".into();
        let mut fences = vec![source.clone(), side, other_screen];
        fences[0].rolled_up = false;
        reflow_fences(&mut fences, &source, None).unwrap();
        assert_eq!(fences[1].geometry.y, 66.0);
        assert_eq!(fences[2].geometry.y, 66.0);
    }

    #[test]
    fn collapse_keeps_deliberate_gaps_and_unrelated_stacks() {
        let source = panel("Top", 20.0, 20.0, 300.0, false);
        let lower = panel("Spaced", 20.0, 400.0, 200.0, false);
        let side = panel("Side", 500.0, 350.0, 200.0, false);
        let side_bottom = panel("Side bottom", 500.0, 558.0, 180.0, false);
        let mut fences = vec![source.clone(), lower, side, side_bottom];
        fences[0].rolled_up = true;
        reflow_fences(&mut fences, &source, None).unwrap();
        assert_eq!(fences[1].geometry.y, 400.0);
        assert_eq!(fences[3].geometry.y, 558.0);
    }

    #[test]
    fn locked_neighbor_blocks_expansion() {
        let source = panel("Top", 20.0, 20.0, 300.0, true);
        let mut lower = panel("Locked", 20.0, 66.0, 200.0, false);
        lower.locked = true;
        let mut fences = vec![source.clone(), lower];
        fences[0].rolled_up = false;
        assert!(
            reflow_fences(&mut fences, &source, None)
                .unwrap_err()
                .contains("locked")
        );
        assert_eq!(fences[1].geometry.y, 66.0);
    }

    #[test]
    fn screen_edge_blocks_expansion() {
        let source = panel("Top", 20.0, 20.0, 800.0, true);
        let lower = panel("Bottom", 20.0, 66.0, 300.0, false);
        let mut fences = vec![source.clone(), lower];
        fences[0].rolled_up = false;
        assert!(
            reflow_fences(&mut fences, &source, None)
                .unwrap_err()
                .contains("screen space")
        );
    }

    #[test]
    fn default_monitor_matches_resolved_primary_display() {
        let source = panel("Top", 20.0, 20.0, 300.0, true);
        let mut lower = panel("Moved", 20.0, 66.0, 200.0, false);
        lower.geometry.monitor = "display-1".into();
        let mut fences = vec![source.clone(), lower];
        fences[0].rolled_up = false;
        reflow_fences(&mut fences, &source, Some("display-1")).unwrap();
        assert_eq!(fences[1].geometry.y, 328.0);
    }

    #[test]
    fn reorder_inserts_into_stack_without_changing_heights() {
        let first = panel("First", 20.0, 20.0, 200.0, false);
        let second = panel("Second", 20.0, 228.0, 180.0, false);
        let third = panel("Third", 20.0, 416.0, 300.0, true);
        let mut fences = vec![first.clone(), second.clone(), third.clone()];
        reorder_fence(&mut fences, third.id, first.id, false).unwrap();
        assert_eq!(fences[2].geometry.y, 20.0);
        assert_eq!(fences[0].geometry.y, 66.0);
        assert_eq!(fences[1].geometry.y, 274.0);
        assert_eq!(fences[2].geometry.h, 300.0);
    }

    #[test]
    fn reorder_respects_locks_and_screen_limits() {
        let first = panel("First", 20.0, 20.0, 200.0, false);
        let mut second = panel("Second", 20.0, 228.0, 180.0, false);
        second.locked = true;
        let mut fences = vec![first.clone(), second.clone()];
        assert!(reorder_fence(&mut fences, first.id, second.id, true).is_err());
        fences[1].locked = false;
        fences[1].geometry.work_h = 300.0;
        assert!(reorder_fence(&mut fences, first.id, second.id, true).is_err());
    }
}
