using Uno;
using Uno.Platform;
using Uno.Collections;
using Uno.Testing;
using Uno.Threading;
using Fuse.Scripting;

namespace Fuse.Scripting.JavaScript
{
	interface IMirror
	{
		object Reflect(Scripting.Context context, object obj);
	}

	class ThreadWorker: IDisposable, IThreadWorker
	{
		public Function Observable { get { return FuseJS.Observable; } }

		JSContext _context;

		static Fuse.Reactive.FuseJS.Builtins _fuseJS;
		public static Fuse.Reactive.FuseJS.Builtins FuseJS { get { return _fuseJS; } }

		readonly Thread _thread;

		readonly ManualResetEvent _ready = new ManualResetEvent(false);
		readonly ManualResetEvent _idle = new ManualResetEvent(true);
		readonly ManualResetEvent _terminate = new ManualResetEvent(false);

		readonly ConcurrentQueue<Action<Scripting.Context>> _queue = new ConcurrentQueue<Action<Scripting.Context>>();
		readonly ConcurrentQueue<Exception> _exceptionQueue = new ConcurrentQueue<Exception>();

		public ThreadWorker()
		{
			_thread = new Thread(Run);
			if defined(DotNet)
			{
				// TODO: Create a method for canceling the thread safely
				// Threads are by default foreground threads
				// Foreground threads prevents the owner process from exiting, before the thread is safely closed
				// This is a workaround by setting the thread to be a background thread.
				_thread.IsBackground = true;
			}

			_thread.Start();
			_ready.WaitOne();
			_ready.Dispose();
		}

		void OnTerminating(Fuse.Platform.ApplicationState newState)
		{
			Dispose();
		}

		public void Dispose()
		{
			Fuse.Platform.Lifecycle.Terminating -= OnTerminating;

			_terminate.Set();
			_thread.Join();
			_terminate.Dispose();
		}

		bool _subscribedForClosing;

		void Run()
		{
			try
			{
				RunInner();
			}
			catch(Exception e)
			{
				Fuse.Diagnostics.UnknownException( "ThreadWorked failed", e, this );
				_exceptionQueue.Enqueue(e);
			}

			if (_context != null)
				_context.Dispose();
		}

		void RunInner()
		{
			try
			{
				_context = Fuse.Scripting.JavaScript.JSContext.Create();

				if (_context == null)
				{
					throw new Exception("Could not create script context");
				}
				UpdateManager.AddAction(CheckAndThrow);

				_fuseJS = new Fuse.Reactive.FuseJS.Builtins(_context);
			}
			finally
			{
				_ready.Set();
			}

			double t = Uno.Diagnostics.Clock.GetSeconds();

			while (true)
			{
				if (_terminate.WaitOne(0))
					break;

				if defined(CPLUSPLUS) extern "uAutoReleasePool ____pool";

				if (!_subscribedForClosing)
				{
					if (Uno.Application.Current != null)
					{
						Fuse.Platform.Lifecycle.Terminating += OnTerminating;
						_subscribedForClosing = true;
					}
				}

				bool didAnything = false;

				Action<Scripting.Context> action;
				if (_queue.TryDequeue(out action))
				{
					try
					{
						didAnything = true;
						action(_context);
					}
					catch (Exception e)
					{
						_exceptionQueue.Enqueue(e);
					}
				}
				else
					_idle.Set();

				try
				{
					_fuseJS.UpdateModules(_context);
				}
				catch (Exception e)
				{
					_exceptionQueue.Enqueue(e);
				}

				var t2 = Uno.Diagnostics.Clock.GetSeconds();

				if (!didAnything || t2-t > 5)
				{
					Thread.Sleep(1);
					t = t2;
				}
			}
		}

		/**
			Waits for any queued items to finish executing. Used only for testing now.
		*/
		public void WaitIdle()
		{
			_idle.WaitOne();
		}

		/*
			Throws an exception that was generated on the thread. If there are more than one then the previous
			ones will be reported and the last one thrown.
		*/
		public void CheckAndThrow()
		{
			Exception next = null, prev = null;
			while (_exceptionQueue.TryDequeue(out next))
			{
				if (prev != null)
					Fuse.Diagnostics.UnknownException("Skipped Exception", prev, this);
				prev = next;
			}

			if (prev != null)
				throw new WrapException(prev);
		}

		public void Invoke(Action<Scripting.Context> action)
		{
			_idle.Reset();
			_queue.Enqueue(action);
		}

		public void Invoke<T>(Uno.Action<Scripting.Context, T> action, T arg0)
		{
			Invoke(new ContextClosureOneArg<T>(action, arg0).Run);
		}

		public void Invoke(Action action)
		{
			Invoke(new ContextIgnoringAction(action).Run);
		}

		public class Fence
		{
			ManualResetEvent _signaled = new ManualResetEvent(false);

			public bool IsSignaled { get { return _signaled.WaitOne(0); } }
			public void Wait() { _signaled.WaitOne(); }

			internal void Signal(Scripting.Context context) { _signaled.Set(); }
		}

		public Fence PostFence()
		{
			var f = new Fence();
			Invoke(f.Signal);
			return f;
		}

		class ContextIgnoringAction
		{
			Uno.Action _action;

			public ContextIgnoringAction(Uno.Action action)
			{
				_action = action;
			}

			public void Run(Scripting.Context context)
			{
				_action();
			}
		}

		class ContextClosureOneArg<T>
		{
			T _arg0;
			Uno.Action<Context, T> _action;

			public ContextClosureOneArg(Uno.Action<Context, T> action, T arg0)
			{
				_action = action;
				_arg0 = arg0;
			}

			public void Run(Context context)
			{
				_action(context, _arg0);
			}
		}
	}
}
