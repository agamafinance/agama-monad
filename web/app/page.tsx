import { redirect } from 'next/navigation';

export default function HomePage() {
  // This deployment carries one network. The other platforms of the app it was
  // forked from are still in the history, and still live on app.agama.finance;
  // here they were dropped so the bundle is Monad and nothing else.
  redirect('/monad');
}
