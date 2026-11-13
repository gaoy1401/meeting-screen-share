#include "meeting/serial_executor.h"

#include <utility>

namespace meeting {

SerialExecutor::SerialExecutor() : worker_([this] { run(); }) {}

SerialExecutor::~SerialExecutor() {
  stop();
}

void SerialExecutor::post(std::function<void()> task) {
  {
    std::lock_guard lock(mutex_);
    if (stopping_) return;
    tasks_.push(std::move(task));
  }
  condition_.notify_one();
}

void SerialExecutor::stop() {
  bool should_join = false;
  {
    std::lock_guard lock(mutex_);
    if (!stopping_) {
      stopping_ = true;
      condition_.notify_one();
    }
    should_join = worker_.joinable() &&
        worker_.get_id() != std::this_thread::get_id();
  }
  if (should_join) {
    worker_.join();
  }
}

void SerialExecutor::run() {
  while (true) {
    std::function<void()> task;
    {
      std::unique_lock lock(mutex_);
      condition_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
      if (tasks_.empty()) {
        if (stopping_) return;
        continue;
      }
      task = std::move(tasks_.front());
      tasks_.pop();
    }
    try {
      task();
    } catch (...) {
      // The owner reports task-specific errors. Keep the executor alive.
    }
  }
}

}  // namespace meeting
