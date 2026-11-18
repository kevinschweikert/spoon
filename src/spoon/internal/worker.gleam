import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision

pub type Error {
  Initialize
  Crashed
}

pub type Job {
  Job(run: fn() -> Nil, on_error: fn(Error) -> Nil)
}

pub type Message {
  Start(Job)
  WorkerDown(process.Down)
}

pub type Manager {
  Manager(
    workers: dict.Dict(process.Pid, Job),
    name: process.Name(Message),
    worker_factory_name: process.Name(
      factory_supervisor.Message(
        process.Name(Message),
        process.Subject(WorkerMessage),
      ),
    ),
  )
}

pub type WorkerMessage {
  Run(job: Job)
}

pub type Worker {
  Worker(manager_name: process.Name(Message))
}

pub fn start_job(name: process.Name(Message), job: Job) {
  let subject = process.named_subject(name)
  process.send(subject, Start(job))
}

pub fn supervised(name: process.Name(Message)) {
  let worker_factory_name: process.Name(
    factory_supervisor.Message(
      process.Name(Message),
      process.Subject(WorkerMessage),
    ),
  ) = process.new_name("worker_factory")
  let worker_factory =
    factory_supervisor.worker_child(start_worker)
    |> factory_supervisor.named(worker_factory_name)
    |> factory_supervisor.restart_strategy(supervision.Temporary)
    |> factory_supervisor.supervised()

  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(
    supervision.worker(fn() { start_manager(name, worker_factory_name) })
    |> supervision.restart(supervision.Permanent),
  )
  |> static_supervisor.add(worker_factory)
  |> static_supervisor.supervised
}

// ---- MANAGER ----
pub fn start_manager(name: process.Name(Message), worker_factory_name) {
  actor.new_with_initialiser(100, fn(self) {
    let selector =
      process.new_selector()
      |> process.select_monitors(WorkerDown)
      |> process.select(self)
    Manager(workers: dict.new(), name:, worker_factory_name:)
    |> actor.initialised()
    |> actor.selecting(selector)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle_manager_message)
  |> actor.start()
}

fn handle_manager_message(manager: Manager, message: Message) {
  case message {
    Start(job) -> {
      case
        factory_supervisor.start_child(
          factory_supervisor.get_by_name(manager.worker_factory_name),
          manager.name,
        )
      {
        Ok(started) -> {
          let workers = dict.insert(manager.workers, started.pid, job)
          process.monitor(started.pid)
          process.send(started.data, Run(job))
          Manager(..manager, workers:)
          |> actor.continue()
        }
        Error(_error) -> {
          job.on_error(Initialize)
          actor.continue(manager)
        }
      }
    }

    WorkerDown(process.ProcessDown(pid:, reason:, ..))
      if reason != process.Normal
    -> {
      case dict.get(manager.workers, pid) {
        Ok(job) -> {
          job.on_error(Crashed)
          let workers = dict.delete(manager.workers, pid)
          Manager(..manager, workers:) |> actor.continue
        }
        Error(_) -> actor.continue(manager)
      }
    }
    WorkerDown(_) -> actor.continue(manager)
  }
}

// ---- WORKER ----
fn start_worker(
  manager_name: process.Name(Message),
) -> Result(actor.Started(process.Subject(WorkerMessage)), actor.StartError) {
  actor.new_with_initialiser(100, fn(self) {
    actor.initialised(Worker(manager_name:))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_worker_message)
  |> actor.start
}

fn handle_worker_message(_worker: Worker, message: WorkerMessage) {
  case message {
    Run(job) -> {
      job.run()
      actor.stop()
    }
  }
}
