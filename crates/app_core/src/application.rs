use std::{
    future::pending,
    path::{Path, PathBuf},
    sync::Arc,
};

use automerge_repo::{
    BootstrapStatus, DocHandle, DocumentId, DocumentStatus, Repo, RepoConfig,
    network::NetworkTransport,
};
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tracing::{error, info, instrument};

use crate::{
    adapters::{FileDocumentStore, LocalTransport, SqliteControlStore},
    domain::{
        CategoryId, CategoryView, CreateCategory, CreateTransaction, FinanceCommand,
        TransactionFilter, TransactionId, TransactionView, UpdateCategory, UpdateTransaction,
        apply_command, decode_finance, initialize_finance,
    },
    error::{AppError, BootstrapError, DomainError, Result},
    events::{ApplicationState, DataChanged, DomainKind, ErrorEvent, ProjectionState},
    projection::{AggregateView, ReadModel, project, reconcile},
};

#[derive(Clone, Debug)]
pub struct AppCoreConfig {
    pub command_capacity: usize,
    pub transient_event_capacity: usize,
    pub repo: RepoConfig,
}

impl Default for AppCoreConfig {
    fn default() -> Self {
        Self {
            command_capacity: 64,
            transient_event_capacity: 128,
            repo: RepoConfig::default(),
        }
    }
}

enum OwnerCommand {
    CreateNew(oneshot::Sender<Result<DocumentId>>),
    Join(DocumentId, oneshot::Sender<Result<()>>),
    Finance(
        FinanceCommand,
        Option<String>,
        Vec<DomainKind>,
        oneshot::Sender<Result<()>>,
    ),
    Shutdown(oneshot::Sender<Result<()>>),
}

/// Cloneable application handle. Mutable orchestration is confined to one bounded owner task.
#[derive(Clone)]
pub struct AppCore {
    commands: mpsc::Sender<OwnerCommand>,
    lifecycle: watch::Receiver<ApplicationState>,
    projection: watch::Receiver<ProjectionState>,
    data_events: broadcast::Sender<DataChanged>,
    error_events: broadcast::Sender<ErrorEvent>,
    read_model: ReadModel,
    data_dir: Arc<PathBuf>,
}

impl std::fmt::Debug for AppCore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppCore")
            .field("data_dir", &self.data_dir)
            .field("lifecycle", &self.lifecycle_state())
            .finish_non_exhaustive()
    }
}

impl AppCore {
    pub async fn open_platform(application_id: &str) -> Result<Self> {
        Self::open(platform_data_dir(application_id)?).await
    }

    pub async fn open(data_dir: impl Into<PathBuf>) -> Result<Self> {
        Self::open_with_config_and_transport(
            data_dir.into(),
            AppCoreConfig::default(),
            LocalTransport::new(),
        )
        .await
    }

    pub async fn open_with_config(
        data_dir: impl Into<PathBuf>,
        config: AppCoreConfig,
    ) -> Result<Self> {
        Self::open_with_config_and_transport(data_dir.into(), config, LocalTransport::new()).await
    }

    pub async fn open_with_transport(
        data_dir: impl Into<PathBuf>,
        transport: Arc<dyn NetworkTransport>,
    ) -> Result<Self> {
        Self::open_with_config_and_transport(data_dir.into(), AppCoreConfig::default(), transport)
            .await
    }

    async fn open_with_config_and_transport(
        data_dir: PathBuf,
        config: AppCoreConfig,
        transport: Arc<dyn NetworkTransport>,
    ) -> Result<Self> {
        if config.command_capacity == 0 || config.transient_event_capacity == 0 {
            return Err(AppError::Storage(
                "application queue capacities must be greater than zero".into(),
            ));
        }
        tokio::fs::create_dir_all(&data_dir)
            .await
            .map_err(|e| AppError::Storage(e.to_string()))?;
        let document_store =
            Arc::new(FileDocumentStore::open(data_dir.join("automerge/documents")).await?);
        let control_store = Arc::new(SqliteControlStore::open(data_dir.join("control.sqlite"))?);
        let read_model = ReadModel::open_disposable(data_dir.join("read-model.sqlite"))?;
        let repo = Repo::open(
            document_store,
            control_store,
            transport,
            config.repo.clone(),
        )
        .await?;

        let initial = match repo.bootstrap_status() {
            BootstrapStatus::NeedsDecision => ApplicationState::NeedsDecision,
            BootstrapStatus::Creating { .. } => ApplicationState::Creating,
            BootstrapStatus::Joining { root } => ApplicationState::Joining { root },
            BootstrapStatus::Ready { root } => ApplicationState::Ready { root },
            BootstrapStatus::Closed => ApplicationState::Closed,
        };
        let (lifecycle_tx, lifecycle) = watch::channel(initial.clone());
        let (projection_tx, projection_rx) = watch::channel(ProjectionState::Unavailable);
        let (data_events, _) = broadcast::channel(config.transient_event_capacity);
        let (error_events, _) = broadcast::channel(config.transient_event_capacity);
        let (commands, command_rx) = mpsc::channel(config.command_capacity);

        let mut root = None;
        if let ApplicationState::Ready { root: root_id } = initial {
            let handle = repo.open_document(root_id).await?;
            projection_tx.send_replace(ProjectionState::Rebuilding);
            match reconcile(&repo, &handle, &read_model).await {
                Ok(checkpoint) => {
                    projection_tx.send_replace(ProjectionState::Ready { checkpoint });
                    root = Some(handle);
                }
                Err(error) => {
                    projection_tx.send_replace(ProjectionState::Failed {
                        message: error.to_string(),
                    });
                    return Err(error);
                }
            }
        }

        tokio::spawn(owner_loop(
            Owner {
                repo: Some(repo),
                root,
                read_model: read_model.clone(),
                lifecycle: lifecycle_tx,
                projection: projection_tx,
                data_events: data_events.clone(),
                error_events: error_events.clone(),
            },
            command_rx,
        ));
        Ok(Self {
            commands,
            lifecycle,
            projection: projection_rx,
            data_events,
            error_events,
            read_model,
            data_dir: Arc::new(data_dir),
        })
    }

    #[must_use]
    pub fn lifecycle_state(&self) -> ApplicationState {
        self.lifecycle.borrow().clone()
    }
    #[must_use]
    pub fn projection_state(&self) -> ProjectionState {
        self.projection.borrow().clone()
    }
    #[must_use]
    pub fn subscribe_lifecycle(&self) -> watch::Receiver<ApplicationState> {
        self.lifecycle.clone()
    }
    #[must_use]
    pub fn subscribe_projection(&self) -> watch::Receiver<ProjectionState> {
        self.projection.clone()
    }
    #[must_use]
    pub fn subscribe_data_changed(&self) -> broadcast::Receiver<DataChanged> {
        self.data_events.subscribe()
    }
    #[must_use]
    pub fn subscribe_errors(&self) -> broadcast::Receiver<ErrorEvent> {
        self.error_events.subscribe()
    }
    #[must_use]
    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub async fn create_new_dataset(&self) -> Result<DocumentId> {
        request(&self.commands, OwnerCommand::CreateNew).await
    }
    pub async fn join_existing(&self, root: DocumentId) -> Result<()> {
        request(&self.commands, |reply| OwnerCommand::Join(root, reply)).await
    }

    pub async fn create_category(&self, command: CreateCategory) -> Result<CategoryId> {
        let id = CategoryId::new();
        self.finance(
            FinanceCommand::CreateCategory(command),
            Some(id.to_string()),
            vec![DomainKind::Categories],
        )
        .await?;
        Ok(id)
    }
    pub async fn update_category(&self, command: UpdateCategory) -> Result<()> {
        self.finance(
            FinanceCommand::UpdateCategory(command),
            None,
            vec![DomainKind::Categories],
        )
        .await
    }
    pub async fn delete_category(&self, id: CategoryId) -> Result<()> {
        self.finance(
            FinanceCommand::DeleteCategory(id),
            None,
            vec![DomainKind::Categories, DomainKind::Transactions],
        )
        .await
    }
    pub async fn create_transaction(&self, command: CreateTransaction) -> Result<TransactionId> {
        let id = TransactionId::new();
        self.finance(
            FinanceCommand::CreateTransaction(command),
            Some(id.to_string()),
            vec![DomainKind::Transactions],
        )
        .await?;
        Ok(id)
    }
    pub async fn update_transaction(&self, command: UpdateTransaction) -> Result<()> {
        self.finance(
            FinanceCommand::UpdateTransaction(command),
            None,
            vec![DomainKind::Transactions],
        )
        .await
    }
    pub async fn delete_transaction(&self, id: TransactionId) -> Result<()> {
        self.finance(
            FinanceCommand::DeleteTransaction(id),
            None,
            vec![DomainKind::Transactions],
        )
        .await
    }
    async fn finance(
        &self,
        command: FinanceCommand,
        generated: Option<String>,
        kinds: Vec<DomainKind>,
    ) -> Result<()> {
        let (reply, receive) = oneshot::channel();
        self.commands
            .send(OwnerCommand::Finance(command, generated, kinds, reply))
            .await
            .map_err(|_| AppError::OwnerStopped)?;
        receive.await.map_err(|_| AppError::OwnerStopped)?
    }

    pub fn categories(&self) -> Result<Vec<CategoryView>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.categories()
    }
    pub fn transactions(&self, filter: &TransactionFilter) -> Result<Vec<TransactionView>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.transactions(filter)
    }
    pub fn aggregates(&self) -> Result<AggregateView> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.aggregates()
    }
    pub async fn shutdown(&self) -> Result<()> {
        request(&self.commands, OwnerCommand::Shutdown).await
    }
}

fn ensure_query_ready(state: ApplicationState) -> Result<()> {
    match state {
        ApplicationState::Ready { .. } => Ok(()),
        ApplicationState::NeedsDecision | ApplicationState::Creating => {
            Err(BootstrapError::DecisionRequired.into())
        }
        ApplicationState::Joining { .. } => Err(BootstrapError::Joining.into()),
        ApplicationState::ShuttingDown | ApplicationState::Closed => {
            Err(BootstrapError::Closed.into())
        }
    }
}

async fn request<T>(
    sender: &mpsc::Sender<OwnerCommand>,
    build: impl FnOnce(oneshot::Sender<Result<T>>) -> OwnerCommand,
) -> Result<T> {
    let (reply, receive) = oneshot::channel();
    sender
        .send(build(reply))
        .await
        .map_err(|_| AppError::OwnerStopped)?;
    receive.await.map_err(|_| AppError::OwnerStopped)?
}

struct Owner {
    repo: Option<Repo>,
    root: Option<DocHandle>,
    read_model: ReadModel,
    lifecycle: watch::Sender<ApplicationState>,
    projection: watch::Sender<ProjectionState>,
    data_events: broadcast::Sender<DataChanged>,
    error_events: broadcast::Sender<ErrorEvent>,
}

#[instrument(skip_all, fields(component = "app_core_owner"))]
async fn owner_loop(mut owner: Owner, mut commands: mpsc::Receiver<OwnerCommand>) {
    let mut document_events = owner.root.as_ref().map(DocHandle::subscribe);
    let mut bootstrap = owner
        .repo
        .as_ref()
        .expect("owner starts with repo")
        .subscribe_bootstrap();
    loop {
        tokio::select! {
            biased;
            command = commands.recv() => {
                let Some(command) = command else { break };
                match command {
                    OwnerCommand::CreateNew(reply) => { let _ = reply.send(owner.create_new().await); document_events = owner.root.as_ref().map(DocHandle::subscribe); }
                    OwnerCommand::Join(root, reply) => { let _ = reply.send(owner.join(root).await); document_events = owner.root.as_ref().map(DocHandle::subscribe); }
                    OwnerCommand::Finance(command, generated, kinds, reply) => { let _ = reply.send(owner.finance(command, generated, kinds).await); }
                    OwnerCommand::Shutdown(reply) => { let result = owner.shutdown().await; let _ = reply.send(result); break; }
                }
            }
            event = recv_document(&mut document_events) => {
                match event {
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => { owner.refresh_projection(vec![DomainKind::Categories, DomainKind::Transactions]).await; },
                    Err(broadcast::error::RecvError::Closed) => { document_events = None; }
                }
            }
            changed = bootstrap.changed() => {
                if changed.is_err() { continue; }
                let bootstrap_state = bootstrap.borrow_and_update().clone();
                if let BootstrapStatus::Ready { root } = bootstrap_state
                    && !matches!(owner.lifecycle.borrow().clone(), ApplicationState::Ready { .. })
                    && let Some(handle) = &owner.root
                    && handle.id() == root
                    && handle.ready().await.is_ok()
                    && owner.refresh_projection(vec![DomainKind::Categories, DomainKind::Transactions]).await
                {
                    owner.lifecycle.send_replace(ApplicationState::Ready { root });
                }
            }
        }
    }
}

async fn recv_document(
    receiver: &mut Option<broadcast::Receiver<automerge_repo::DocumentEvent>>,
) -> std::result::Result<automerge_repo::DocumentEvent, broadcast::error::RecvError> {
    match receiver {
        Some(receiver) => receiver.recv().await,
        None => pending().await,
    }
}

impl Owner {
    async fn create_new(&mut self) -> Result<DocumentId> {
        if !matches!(
            self.lifecycle.borrow().clone(),
            ApplicationState::NeedsDecision
        ) {
            return Err(BootstrapError::DecisionAlreadyMade.into());
        }
        self.lifecycle.send_replace(ApplicationState::Creating);
        info!(lifecycle = "creating", "application lifecycle transition");
        let repo = self.repo.as_ref().ok_or(BootstrapError::Closed)?;
        let handle = repo.initialize_new().await?;
        let default_id = CategoryId::new();
        handle
            .change(move |tx| initialize_finance(tx, default_id))
            .await?;
        self.projection.send_replace(ProjectionState::Projecting);
        let checkpoint = project(repo, &handle, &self.read_model).await?;
        self.projection.send_replace(ProjectionState::Ready {
            checkpoint: checkpoint.clone(),
        });
        self.lifecycle
            .send_replace(ApplicationState::Ready { root: handle.id() });
        info!(lifecycle = "ready", root = %handle.id(), checkpoint = %checkpoint.heads, "application lifecycle transition");
        self.root = Some(handle.clone());
        let _ = self.data_events.send(DataChanged {
            kinds: vec![DomainKind::Categories],
            checkpoint,
        });
        Ok(handle.id())
    }

    async fn join(&mut self, root: DocumentId) -> Result<()> {
        if !matches!(
            self.lifecycle.borrow().clone(),
            ApplicationState::NeedsDecision
        ) {
            return Err(BootstrapError::DecisionAlreadyMade.into());
        }
        let handle = self
            .repo
            .as_ref()
            .ok_or(BootstrapError::Closed)?
            .join_existing(root)
            .await?;
        self.root = Some(handle);
        self.lifecycle
            .send_replace(ApplicationState::Joining { root });
        self.projection.send_replace(ProjectionState::Unavailable);
        info!(lifecycle = "joining", root = %root, "application lifecycle transition");
        Ok(())
    }

    #[instrument(skip_all, fields(command = command_name(&command)))]
    async fn finance(
        &mut self,
        command: FinanceCommand,
        generated: Option<String>,
        kinds: Vec<DomainKind>,
    ) -> Result<()> {
        command.validate()?;
        let handle = self
            .root
            .as_ref()
            .ok_or_else(|| match self.lifecycle.borrow().clone() {
                ApplicationState::Joining { .. } => AppError::from(BootstrapError::Joining),
                _ => AppError::from(BootstrapError::DecisionRequired),
            })?;
        if handle.status() != DocumentStatus::Ready {
            return Err(BootstrapError::Joining.into());
        }
        let validation_command = command.clone();
        handle
            .read(move |doc| validate_against_snapshot(&decode_finance(doc)?, &validation_command))
            .await??;
        handle
            .change(move |tx| apply_command(tx, &command, generated))
            .await?;
        self.projection.send_replace(ProjectionState::Projecting);
        let repo = self.repo.as_ref().ok_or(BootstrapError::Closed)?;
        match project(repo, handle, &self.read_model).await {
            Ok(checkpoint) => {
                self.projection.send_replace(ProjectionState::Ready {
                    checkpoint: checkpoint.clone(),
                });
                info!(checkpoint = %checkpoint.heads, "projection committed");
                let _ = self.data_events.send(DataChanged { kinds, checkpoint });
                Ok(())
            }
            Err(failure) => {
                self.report_projection_error(&failure);
                Err(failure)
            }
        }
    }

    async fn refresh_projection(&mut self, kinds: Vec<DomainKind>) -> bool {
        let (Some(repo), Some(handle)) = (&self.repo, &self.root) else {
            return false;
        };
        if handle.status() != DocumentStatus::Ready {
            return false;
        }
        let before = self.read_model.checkpoint().ok().flatten();
        self.projection.send_replace(ProjectionState::Projecting);
        match reconcile(repo, handle, &self.read_model).await {
            Ok(checkpoint) => {
                self.projection.send_replace(ProjectionState::Ready {
                    checkpoint: checkpoint.clone(),
                });
                if before.as_ref() != Some(&checkpoint) {
                    let _ = self.data_events.send(DataChanged { kinds, checkpoint });
                }
                true
            }
            Err(failure) => {
                self.report_projection_error(&failure);
                false
            }
        }
    }

    fn report_projection_error(&self, failure: &AppError) {
        let message = failure.to_string();
        error!(operation = "projection", error = %message, "application operation failed");
        self.projection.send_replace(ProjectionState::Failed {
            message: message.clone(),
        });
        let _ = self.error_events.send(ErrorEvent {
            operation: "projection",
            message,
        });
    }

    async fn shutdown(&mut self) -> Result<()> {
        self.lifecycle.send_replace(ApplicationState::ShuttingDown);
        info!(
            lifecycle = "shutting_down",
            "application lifecycle transition"
        );
        if let (Some(repo), Some(handle)) = (&self.repo, &self.root) {
            let _ = project(repo, handle, &self.read_model).await;
        }
        let result = match self.repo.take() {
            Some(repo) => repo.shutdown().await.map_err(AppError::from),
            None => Ok(()),
        };
        self.projection.send_replace(ProjectionState::Closed);
        self.lifecycle.send_replace(ApplicationState::Closed);
        result
    }
}

fn command_name(command: &FinanceCommand) -> &'static str {
    match command {
        FinanceCommand::CreateCategory(_) => "create_category",
        FinanceCommand::UpdateCategory(_) => "update_category",
        FinanceCommand::DeleteCategory(_) => "delete_category",
        FinanceCommand::CreateTransaction(_) => "create_transaction",
        FinanceCommand::UpdateTransaction(_) => "update_transaction",
        FinanceCommand::DeleteTransaction(_) => "delete_transaction",
    }
}

fn validate_against_snapshot(
    snapshot: &crate::domain::FinanceSnapshot,
    command: &FinanceCommand,
) -> std::result::Result<(), DomainError> {
    let category_available = |id: CategoryId| {
        snapshot
            .categories
            .iter()
            .any(|item| item.id == id && !item.deleted)
    };
    match command {
        FinanceCommand::CreateCategory(_) => Ok(()),
        FinanceCommand::UpdateCategory(value) => snapshot
            .categories
            .iter()
            .any(|item| item.id == value.id && !item.deleted)
            .then_some(())
            .ok_or_else(|| DomainError::NotFound {
                kind: "category",
                id: value.id.to_string(),
            }),
        FinanceCommand::DeleteCategory(id) => snapshot
            .categories
            .iter()
            .any(|item| item.id == *id)
            .then_some(())
            .ok_or_else(|| DomainError::NotFound {
                kind: "category",
                id: id.to_string(),
            }),
        FinanceCommand::CreateTransaction(value) => category_available(value.category_id)
            .then_some(())
            .ok_or_else(|| DomainError::CategoryUnavailable(value.category_id.to_string())),
        FinanceCommand::UpdateTransaction(value) => {
            if !snapshot
                .transactions
                .iter()
                .any(|item| item.id == value.id && !item.deleted)
            {
                return Err(DomainError::NotFound {
                    kind: "transaction",
                    id: value.id.to_string(),
                });
            }
            if let Some(id) = value.category_id
                && !category_available(id)
            {
                return Err(DomainError::CategoryUnavailable(id.to_string()));
            }
            Ok(())
        }
        FinanceCommand::DeleteTransaction(id) => snapshot
            .transactions
            .iter()
            .any(|item| item.id == *id)
            .then_some(())
            .ok_or_else(|| DomainError::NotFound {
                kind: "transaction",
                id: id.to_string(),
            }),
    }
}

/// Resolves a conventional per-platform application-data directory.
pub fn platform_data_dir(application_id: &str) -> Result<PathBuf> {
    if application_id.is_empty() || application_id.contains(['/', '\\']) {
        return Err(AppError::Storage(
            "application id must be one path component".into(),
        ));
    }
    #[cfg(target_os = "windows")]
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(target_os = "macos")]
    let base = std::env::var_os("HOME")
        .map(|path| PathBuf::from(path).join("Library/Application Support"));
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|path| PathBuf::from(path).join(".local/share")));
    base.map(|path| path.join(application_id)).ok_or_else(|| {
        AppError::Storage("platform application-data directory is unavailable".into())
    })
}
